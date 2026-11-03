#!/bin/bash
# gh-identity: app-token
# bin/ci-image-rollout.sh — file one child ticket per fleet repo that runs CI,
# on that repo's OWN board, to move its CI onto the prebuilt image (BH-7256,
# slice 4 of the CI images work; docs/CI-IMAGES.md "Rollout (slice 4)").
#
#   ci-image-rollout.sh targets                      <project> TAB <repo> TAB <gh|app>
#   ci-image-rollout.sh body <project>               the rendered child body (no network)
#   ci-image-rollout.sh plan [<project>|--all]       <project> TAB <repo> TAB <kind> TAB <verdict>
#   ci-image-rollout.sh file <project>|--all [--apply]
#
# TARGETS are `bin/fleet-conf.sh --projects` minus every sandbox repo. No
# project is left out by name: a repo already on the image (slices 2 and 3 of
# this work) is found by what it holds, and gets the verdict on-image (below).
# A sandbox is a project whose name has the dash token `sbx` (cromford-sbx-linear) or whose
# repo name holds `sandbox` in any case (example-org/cromford-sandbox-jira);
# fleet.conf has no sandbox column. A child build runs in its own repo's lane, which starts
# from a ticket on that project's board; a child on the cromford board
# would build in cromford. So each child goes to its own board.
#
# VERDICTS (`plan`, and `file` decides the same way first):
#   on-image       the repo is already on the image: `.github/workflows` holds
#                  a file named exactly ci-image.yml or ci-image.yaml, or
#                  `ci/ci-image.conf` is a file (a merged child PR adds it).
#                  No dedup read, no child.
#   runs-ci        `.github/workflows` holds one or more *.yml / *.yaml files,
#                  and the repo is not on-image (the conf read answered 404)
#   no-ci          the repo is readable and has no such file (404 on the path,
#                  or only other files)
#   filed <ref>    runs-ci, and a ticket with this repo's marker line exists
#   unknown <why>  anything the reads could not decide: an unreadable repo, a
#                  rate limit (gh rc 75, docs/GH-REST.md), an empty or
#                  unparseable answer, a failed conf or dedup read, no board token or
#                  base. NEVER counted as no-ci or as "none filed".
#
# THE MARKER is the last line of every child body:
#   ci-image-rollout-of: BH-7256 repo=<owner/repo>
# A ticket is already filed when its body (GitHub board, REST issue search
# over all states) or its description (app board) holds that line for THIS
# repo, or, on an app board, when its title equals the child title (the list
# route may omit description; docs/BOARD-API-CONTRACT.md). The dedup read runs
# BEFORE each create; a failed or incomplete read refuses that project.
#
# `file` without --apply prints `would file <project> <repo> :: <title>` and
# creates nothing. With --apply it creates each missing child:
#   GitHub board (fleet.conf board prefix `-`): POST repos/<repo>/issues with
#     the `ai-build` label, so that project's watcher builds it
#   app board: POST <base>/boards/<first board id>/tickets, the token from the
#     project's env file (bin/lib/internal-token.sh) in a header only
# It prints `filed <project> <ref>` only after the answer carries a number or
# id, else `create-failed <project> <first 200 chars>`. A rerun files only the
# missing ones, but GitHub search indexes a new issue some time after the
# create: an --apply that filed on a GitHub board prints one stderr line that
# says to wait before a re-run, because a fast re-run can file a duplicate.
#
# KNOBS (catalog/lanes.d/_lib.ci-image-rollout.json, read through
# lib_env_apply ci-image-rollout): CI_ROLLOUT_CURL_MAX_TIME (app-board curl
# --max-time, default 25 s) and CI_ROLLOUT_SEARCH_PER_PAGE (the dedup search
# per_page, default 100).
#
# Exit: 0 every target decided (filed, already filed, on-image, no-ci, or would file);
# 1 one or more targets unknown or a create failed (named per line), or the
# target list is unreadable; 2 misuse (nothing is read).
#
# Seams: HARNESS (the env dir root, default /root/harness), FLEET_CONF (read by
# bin/fleet-conf.sh), HARNESS_ENV_DIR, gh and curl found on PATH, and the
# lane-gate seams LANE_REGISTRY, LANE_GATE_NOW, LANE_GATE_DISABLE.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
KIT="$ROOT/ci-images/project-layer"
FCS="$HERE/fleet-conf.sh"
# The entry point owns the root default; the libs read HARNESS, then H (D43).
H="${HARNESS:-/root/harness}"
export H
TICKET=BH-7256
MARKER_PREFIX="ci-image-rollout-of: $TICKET repo="
BOARD_LABEL=ai-build

# shellcheck source=bin/lib/file-children.sh
. "$HERE/lib/file-children.sh" 2>/dev/null || { echo "ci-image-rollout: cannot read $HERE/lib/file-children.sh" >&2; exit 2; }
# shellcheck source=bin/lib/board-creds.sh
. "$HERE/lib/board-creds.sh" 2>/dev/null || { echo "ci-image-rollout: cannot read $HERE/lib/board-creds.sh" >&2; exit 2; }
# shellcheck source=bin/lib/env-path.sh
. "$HERE/lib/env-path.sh" 2>/dev/null || { echo "ci-image-rollout: cannot read $HERE/lib/env-path.sh" >&2; exit 2; }
# Each repo's reads and its create go out on that repo's App token when the box
# mints them (gh_auth_for, per repo); an unarmed box runs on the ambient gh auth.
# shellcheck source=bin/lib/gh-app-auth.sh
. "$HERE/lib/gh-app-auth.sh" 2>/dev/null || { gh_auth_for() { return 1; }; gh_auth_reset() { return 0; }; }
# The knobs as settings rows: a lib.ci-image-rollout.<env lowercased> row is
# exported here. No lane-gate, LANE_GATE_DISABLE=1 or no row leaves the env.
# shellcheck source=bin/lib/lane-gate.sh
. "$HERE/lib/lane-gate.sh" 2>/dev/null || true
[ "${LANE_GATE_DISABLE:-0}" = 1 ] || { command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply ci-image-rollout; } >/dev/null 2>&1 || true

# knob_int <value> <fallback> <min> <max> — a whole number clamped to min..max;
# anything else is the fallback.
knob_int() {
  local v="$1"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  v=$((10#$v))
  [ "$v" -lt "$3" ] && v="$3"
  [ "$v" -gt "$4" ] && v="$4"
  printf '%s' "$v"
}
# Fallback 25 s; row lib.ci-image-rollout.ci_rollout_curl_max_time.
CURL_MAX_TIME=$(knob_int "${CI_ROLLOUT_CURL_MAX_TIME:-25}" 25 5 120)
# Fallback 100 (GitHub's search cap); row lib.ci-image-rollout.ci_rollout_search_per_page.
SEARCH_PER_PAGE=$(knob_int "${CI_ROLLOUT_SEARCH_PER_PAGE:-100}" 100 1 100)

usage() {
  echo "usage: ci-image-rollout.sh targets | body <project> | plan [<project>|--all] | file <project>|--all [--apply]" >&2
  exit 2
}

TMP=$(mktemp -d) || { echo "ci-image-rollout: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# is_sandbox <project> <repo> — rc 0 for a sandbox: the dash token `sbx` in
# the project name, or `sandbox` in the repo name (any case).
is_sandbox() {
  local p name
  p=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  name=$(printf '%s' "${2##*/}" | tr '[:upper:]' '[:lower:]')
  [[ "$p" =~ (^|-)sbx(-|$) ]] && return 0
  case "$name" in *sandbox*) return 0 ;; esac
  return 1
}

title_for() { printf 'CI images: run %s CI on the prebuilt image (%s slice 4)\n' "$1" "$TICKET"; }

# targets_tsv — the target rows, or rc 1 when fleet.conf is unreadable.
targets_tsv() {
  local projects p repo prefix kind
  projects=$("$FCS" --projects 2>/dev/null) || { echo "ci-image-rollout: bin/fleet-conf.sh --projects failed" >&2; return 1; }
  [ -n "$projects" ] || { echo "ci-image-rollout: bin/fleet-conf.sh --projects is empty" >&2; return 1; }
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    repo=$("$FCS" "$p" repo 2>/dev/null) || repo=""
    is_sandbox "$p" "$repo" && continue
    prefix=$("$FCS" "$p" board_prefix 2>/dev/null) || prefix=""
    if [ "$prefix" = "-" ]; then kind=gh; else kind=app; fi
    printf '%s\t%s\t%s\n' "$p" "${repo:--}" "$kind"
  done <<< "$projects"
}

# render_body <repo> — the child body: the template with the kit files inline.
render_body() {
  local repo="$1" image line f
  image="ghcr.io/example-org/$(printf '%s' "${repo##*/}" | tr '[:upper:]' '[:lower:]')-ci"
  for f in child-ticket.md Dockerfile ci-image.sh ci-image.conf ci-image-job.yml; do
    [ -r "$KIT/$f" ] || { echo "ci-image-rollout: cannot read kit file $KIT/$f" >&2; return 1; }
  done
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      @@KIT_DOCKERFILE@@) cat "$KIT/Dockerfile" ;;
      @@KIT_SCRIPT@@)     cat "$KIT/ci-image.sh" ;;
      @@KIT_CONF@@)       sed "s|^image=.*|image=$image|" "$KIT/ci-image.conf" ;;
      @@KIT_JOB@@)        cat "$KIT/ci-image-job.yml" ;;
      *) line="${line//@@REPO@@/$repo}"; printf '%s\n' "${line//@@IMAGE@@/$image}" ;;
    esac
  done < "$KIT/child-ticket.md"
}

# marker_re <repo> — the jq regex for this repo's marker line.
marker_re() {
  local r="${1//./\\.}"
  printf '(^|[\\n>])%s%s($|[^A-Za-z0-9._/-])' "$MARKER_PREFIX" "$r"
}

# ci_verdict <repo> -> on-image | runs-ci | no-ci | unknown <why>
ci_verdict() {
  local repo="$1" out rc names code
  case "$repo" in
    */*) ;;
    *) echo "unknown no-repo-in-fleet-conf"; return ;;
  esac
  out=$(gh api "repos/$repo/contents/.github/workflows" 2>"$TMP/err"); rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -n "$out" ] || { echo "unknown empty-answer"; return; }
    names=$(printf '%s' "$out" | jq -r 'if type == "array" then .[] | select(.type == "file") | .name else error("not a list") end' 2>/dev/null) \
      || { echo "unknown workflows-unparseable"; return; }
    grep -Eqx 'ci-image\.ya?ml' <<< "$names" && { echo on-image; return; }
    grep -Eq '\.ya?ml$' <<< "$names" || { echo no-ci; return; }
    conf_verdict "$repo"; return
  fi
  [ "$rc" -eq 75 ] && { echo "unknown rate-limited"; return; }
  code=$(grep -Eo 'HTTP [0-9]{3}' "$TMP/err" | head -1 | tr -d ' ')
  if [ "$code" = HTTP404 ]; then
    # The path is absent, or the whole repo is invisible to this token. Only a
    # readable repo makes it no-ci.
    gh api "repos/$repo" >/dev/null 2>"$TMP/err"; rc=$?
    [ "$rc" -eq 0 ] && { echo no-ci; return; }
    [ "$rc" -eq 75 ] && { echo "unknown rate-limited"; return; }
    echo "unknown repo-unreadable"; return
  fi
  if [ -n "$code" ]; then echo "unknown gh-${code#HTTP}"; else echo "unknown gh-rc-$rc"; fi
}

# conf_verdict <repo> -> on-image | runs-ci | unknown <why>: the repo runs CI;
# a ci/ci-image.conf file means a child PR already moved it onto the image.
conf_verdict() {
  local repo="$1" out rc
  out=$(gh api "repos/$repo/contents/ci/ci-image.conf" 2>"$TMP/err"); rc=$?
  if [ "$rc" -eq 0 ]; then
    if printf '%s' "$out" | jq -e 'type == "object" and .type == "file"' >/dev/null 2>&1; then echo on-image; else echo "unknown conf-read-failed"; fi
    return
  fi
  [ "$rc" -eq 75 ] && { echo "unknown rate-limited"; return; }
  if grep -q 'HTTP 404' "$TMP/err"; then echo runs-ci; else echo "unknown conf-read-failed"; fi
}

# gh_existing <repo> -> "none" or "<repo>#<n>"; rc 1 when the read failed.
gh_existing() {
  local repo="$1" out n
  out=$(gh api -X GET search/issues -f q="repo:$repo is:issue in:body \"$MARKER_PREFIX$repo\"" -f per_page="$SEARCH_PER_PAGE" 2>/dev/null) || return 1
  n=$(printf '%s' "$out" | jq -r --arg re "$(marker_re "$repo")" '
      if (.items | type) != "array" or .incomplete_results != false then error("incomplete")
      else [.items[] | select((.body // "") | test($re)) | .number] | first // "none" end' 2>/dev/null) || return 1
  [ -n "$n" ] || return 1
  if [ "$n" = none ]; then echo none; else echo "$repo#$n"; fi
}

# app_ctx <project> — sets BASE, TOKEN, BOARD_ID, or prints `unknown <why>` and rc 1.
app_ctx() {
  local p="$1" envfile var boards
  BASE=""; TOKEN=""; BOARD_ID=""
  envfile="$(harness_env_dir "$H")/$p.env"
  [ -r "$envfile" ] || { echo "unknown no-env-file"; return 1; }
  var=$(internal_token_var "$envfile" 2>/dev/null) || var=""
  [ -n "$var" ] || { echo "unknown no-board-token"; return 1; }
  TOKEN=$(board_env_value "$var" "$envfile")
  [ -n "$TOKEN" ] || { echo "unknown no-board-token"; return 1; }
  BASE=$(fc_board_base "$p") || BASE=""
  [ -n "$BASE" ] || { echo "unknown no-board-base"; return 1; }
  boards=$(app_get "$BASE/boards") || { echo "unknown boards-read-failed"; return 1; }
  BOARD_ID=$(printf '%s' "$boards" | jq -r '(if type == "array" then . else .boards end) | if type == "array" then (.[0].id // empty | tostring) else empty end' 2>/dev/null)
  [ -n "$BOARD_ID" ] || { echo "unknown no-board-id"; return 1; }
}

# app_call <method> <url> [<payload file>] — the body on stdout; rc 1 on a
# transport error or a non-2xx status. The token rides in a header file.
app_call() {
  local method="$1" url="$2" data="${3:-}" code
  local -a args=(-sS --max-time "$CURL_MAX_TIME" -X "$method" -H "@$TMP/hdr" -o "$TMP/resp" -w '%{http_code}')
  printf 'Authorization: Bearer %s\nContent-Type: application/json\nUser-Agent: curl/8\n' "$TOKEN" > "$TMP/hdr"
  [ -n "$data" ] && args+=(--data-binary "@$data")
  : > "$TMP/resp"
  code=$(curl "${args[@]}" "$url" 2>/dev/null) || { rm -f "$TMP/hdr"; return 1; }
  rm -f "$TMP/hdr"
  cat "$TMP/resp"
  case "$code" in 2??) return 0 ;; *) return 1 ;; esac
}
app_get() { app_call GET "$1"; }

# app_existing <project> <repo> -> "none" or the ticket ref; rc 1 on a failed read.
app_existing() {
  local p="$1" repo="$2" out ref
  out=$(app_get "$BASE/boards/$BOARD_ID/tickets") || return 1
  ref=$(printf '%s' "$out" | jq -r --arg re "$(marker_re "$repo")" --arg t "$(title_for "$repo")" '
      (if type == "array" then . else .tickets end) | if type != "array" then error("not a list") else
      [.[] | select(((.description // "") | test($re)) or (.title == $t)) | (.key // .number // .id | tostring)] | first // "none" end' 2>/dev/null) || return 1
  [ -n "$ref" ] || return 1
  echo "$ref"
}

# decide <project> <repo> <kind> -> runs-ci | on-image | no-ci | filed <ref> | unknown <why>
decide() {
  local p="$1" repo="$2" kind="$3" v ex
  gh_auth_for "$repo" || true
  v=$(ci_verdict "$repo")
  [ "$v" = runs-ci ] || { echo "$v"; return; }
  if [ "$kind" = gh ]; then
    ex=$(gh_existing "$repo") || { echo "unknown dedup-read-failed"; return; }
  else
    app_ctx "$p" || return
    ex=$(app_existing "$p" "$repo") || { echo "unknown dedup-read-failed"; return; }
  fi
  if [ "$ex" = none ]; then echo runs-ci; else echo "filed $ex"; fi
}

# create <project> <repo> <kind> -> prints `filed` or `create-failed`; rc 1 on a failure.
create() {
  local p="$1" repo="$2" kind="$3" title out n
  title=$(title_for "$repo")
  render_body "$repo" > "$TMP/body.md" || { echo "create-failed $p kit unreadable"; return 1; }
  if [ "$kind" = gh ]; then
    gh_auth_for "$repo" || true
    out=$(gh api -X POST "repos/$repo/issues" -f title="$title" -F body=@"$TMP/body.md" -f "labels[]=$BOARD_LABEL" 2>&1)
    gh_auth_reset
    n=$(printf '%s' "$out" | jq -r '.number // empty | tostring' 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "create-failed $p $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"; return 1; }
    echo "filed $p $repo#$n"
  else
    jq -n --arg t "$title" --rawfile d "$TMP/body.md" '{title:$t, description:$d, priority:"low"}' > "$TMP/payload.json" \
      || { echo "create-failed $p payload"; return 1; }
    out=$(app_call POST "$BASE/boards/$BOARD_ID/tickets" "$TMP/payload.json") \
      || { echo "create-failed $p $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"; return 1; }
    n=$(printf '%s' "$out" | jq -r '(.ticket // .) | (.key // .number // .id // empty) | tostring' 2>/dev/null)
    [ -n "$n" ] || { echo "create-failed $p $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"; return 1; }
    echo "filed $p $n"
  fi
}

# select_rows <project>|--all — the target rows to act on; rc 2 for a project
# that is not a target.
select_rows() {
  local want="$1" rows
  rows=$(targets_tsv) || exit 1
  if [ "$want" = --all ]; then printf '%s\n' "$rows"; return; fi
  printf '%s\n' "$rows" | awk -F'\t' -v p="$want" '$1 == p' | grep . \
    || { echo "ci-image-rollout: '$want' is not a rollout target (see: ci-image-rollout.sh targets)" >&2; exit 2; }
}

cmd_plan() {
  local want="${1:---all}" rows p repo kind v rc=0
  [ $# -le 1 ] || usage
  case "$want" in --apply) usage ;; esac
  rows=$(select_rows "$want") || exit $?
  while IFS=$'\t' read -r p repo kind; do
    v=$(decide "$p" "$repo" "$kind" </dev/null)
    case "$v" in unknown*) rc=1 ;; esac
    printf '%s\t%s\t%s\t%s\n' "$p" "$repo" "$kind" "$v"
  done <<< "$rows"
  return "$rc"
}

cmd_file() {
  local want="" apply=0 a rows p repo kind v rc=0 gh_filed=0
  for a in "$@"; do
    case "$a" in
      --apply) apply=1 ;;
      -*) [ "$a" = --all ] && [ -z "$want" ] && want=--all || usage ;;
      *) [ -z "$want" ] && want="$a" || usage ;;
    esac
  done
  [ -n "$want" ] || usage
  rows=$(select_rows "$want") || exit $?
  while IFS=$'\t' read -r p repo kind; do
    v=$(decide "$p" "$repo" "$kind" </dev/null)
    case "$v" in
      no-ci)    echo "no-ci $p $repo" ;;
      on-image) echo "on-image $p $repo" ;;
      filed\ *) echo "already-filed $p ${v#filed }" ;;
      unknown*) echo "unknown $p $repo ${v#unknown }"; rc=1 ;;
      runs-ci)
        if [ "$apply" = 0 ]; then
          echo "would file $p $repo :: $(title_for "$repo")"
        else
          # decide ran in a subshell; the app context is read again here.
          if [ "$kind" = app ]; then app_ctx "$p" >/dev/null || { echo "unknown $p $repo board-context-lost"; rc=1; continue; }; fi
          if create "$p" "$repo" "$kind" </dev/null; then
            [ "$kind" = gh ] && gh_filed=1
          else
            rc=1
          fi
        fi ;;
      *) echo "unknown $p $repo verdict '$v'"; rc=1 ;;
    esac
  done <<< "$rows"
  [ "$gh_filed" = 1 ] && echo "ci-image-rollout: GitHub search needs time to index new issues; wait before an --apply re-run, or it can file a duplicate (docs/CI-IMAGES.md)" >&2
  return "$rc"
}

cmd_body() {
  local p="${1:-}" row
  [ $# -eq 1 ] && [ -n "$p" ] || usage
  row=$(select_rows "$p") || exit $?
  render_body "$(cut -f2 <<< "${row%%$'\n'*}")" || exit 1
}

case "${1:-}" in
  targets) [ $# -eq 1 ] || usage; targets_tsv || exit 1 ;;
  body)    shift; cmd_body "$@" ;;
  plan)    shift; cmd_plan "$@"; exit $? ;;
  file)    shift; cmd_file "$@"; exit $? ;;
  *) usage ;;
esac
