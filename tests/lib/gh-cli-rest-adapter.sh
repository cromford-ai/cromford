#!/bin/bash
# tests/lib/gh-cli-rest-adapter.sh — BH-1650. The issue reads/writes of
# bin/lib/fc-issues.sh, bin/unblocked-children.sh and bin/decompose-parent-close.sh
# moved from `gh issue view|list|edit|comment` to bin/lib/gh-rest.sh. The fixture
# suites that drive them wrote their GitHub as CLI-shaped stubs; this answers the
# new `gh api -i` calls FROM those same stubs, so no scenario changes:
#
#   GET  repos/S/issues?...page=N  -> "$self" issue list -R S --label L --state all ...
#                                     (page 1 only; state lower-cased as REST does)
#   GET  repos/S/issues/N          -> "$self" issue view N ... (labels + title)
#   DELETE .../issues/N/labels/L   -> "$self" issue edit N -R S --remove-label L
#   POST .../issues/N/comments     -> "$self" issue comment N -R S --body-file F
#                                     (these three only with `post` as the second
#                                     argument; without it only the list is served)
#   POST repos/S/issues (no -i)    -> "$self" issue create -R S --title T --label L
#                                     ... --body-file F (BH-8962: the REST create of
#                                     bin/lib/tracker/gh-issue-create.sh; with `post`,
#                                     or on its own through gh_cli_rest_create)
#
# BH-949 moved decompose-parent-close.sh's two remaining GraphQL reads (the PR
# list and the parent by number) to REST as well. Those two routes are served
# only with GH_CLI_REST_READS=1 in the environment, because other suites'
# stubs answer `GET repos/S/pulls` themselves and must keep doing so:
#
#   GET  repos/S/pulls?...page=N   -> "$self" pr list -R S --state all ...
#                                     (REST shape: html_url, head.ref, merged_at)
#   api  repos/S/issues/N (no -i)  -> "$self" issue view N ... (number, state,
#                                     title, labels; state lower-cased)
#
# The issue list also carries a CLI `stateReason` over as REST's `state_reason`.
#
# A stub wires it in as the first thing it does after logging its argv:
#   . "$DIR/tests/lib/gh-cli-rest-adapter.sh" || exit 1
#   gh_cli_rest "$0" [post] "$@" && exit 0
# rc 1 = not a route this adapter answers; the stub carries on as before.
gh_cli_rest() {
  local self="$1" post=0 a m="" p="" prev="" page=1 lbl="" st="" n out rc
  shift
  [ "${1:-}" = post ] && { post=1; shift; }
  [ "$post" = 1 ] && gh_cli_rest_create "$self" "$@" && return 0
  if [ "${GH_CLI_REST_READS:-}" = 1 ] && [ "$#" = 2 ] && [ "$1" = api ]; then
    case "$2" in
      repos/*/issues/[0-9]*)
        n="${2##*/issues/}"; case "$n" in *[!0-9]*) return 1 ;; esac
        p="${2#repos/}"; p="${p%%/issues/*}"
        out=$("$self" issue view "$n" -R "$p" --json number,state,title,labels 2>/dev/null) || return 0
        printf '%s' "$out" | jq -c '.state |= (tostring|ascii_downcase)' 2>/dev/null
        return 0 ;;
    esac
  fi
  case " $* " in *" api -i "*|"api -i "*) ;; *) return 1 ;; esac
  for a in "$@"; do
    [ "$prev" = -X ] && m="$a"
    case "$a" in repos/*) p="$a" ;; page=*) page="${a#page=}" ;; labels=*) lbl="${a#labels=}" ;;
                 state=*) st="${a#state=}" ;; body=@*) bf="${a#body=@}" ;; esac
    prev="$a"
  done
  local slug="${p#repos/}"; slug="${slug%%/issues*}"
  _gcr_send() { printf 'HTTP/2.0 %s X\r\n\r\n%s\n' "$1" "$2"; }
  case "$m $p" in
    "GET repos/"*/issues)
      [ "$page" != 1 ] && { _gcr_send 200 '[]'; return 0; }
      rc=0; out=$("$self" issue list -R "$slug" ${lbl:+--label "$lbl"} --state "${st:-all}" --limit 100 --json number,state,title,body 2>/dev/null) || rc=$?
      [ "$rc" = 0 ] || { _gcr_send 500 '{}'; return 0; }
      out=$(printf '%s' "${out:-[]}" | jq -c 'map(.state |= (tostring|ascii_downcase)
        | if has("stateReason") then .state_reason = (if .stateReason == null then null
            else (.stateReason|tostring|ascii_downcase) end) | del(.stateReason) else . end)' 2>/dev/null) || { _gcr_send 200 ''; return 0; }
      _gcr_send 200 "$out"; return 0 ;;
    "GET repos/"*/pulls)
      [ "${GH_CLI_REST_READS:-}" = 1 ] || return 1
      [ "$page" != 1 ] && { _gcr_send 200 '[]'; return 0; }
      slug="${p#repos/}"; slug="${slug%%/pulls*}"
      rc=0; out=$("$self" pr list -R "$slug" --state "${st:-all}" --limit 100 --json number,url,title,headRefName,state 2>/dev/null) || rc=$?
      [ "$rc" = 0 ] || { _gcr_send 500 '{}'; return 0; }
      out=$(printf '%s' "${out:-[]}" | jq -c 'map({number, html_url:.url, title, head:{ref:.headRefName},
        state:(if (.state|tostring|ascii_upcase) == "OPEN" then "open" else "closed" end),
        merged_at:(if (.state|tostring|ascii_upcase) == "MERGED" then "2026-01-01T00:00:00Z" else null end)})' 2>/dev/null) \
        || { _gcr_send 200 ''; return 0; }
      _gcr_send 200 "$out"; return 0 ;;
    "GET repos/"*/issues/[0-9]*)
      [ "$post" = 1 ] || return 1
      n="${p##*/issues/}"; case "$n" in *[!0-9]*) return 1 ;; esac
      local lj tj
      rc=0; lj=$("$self" issue view "$n" -R "$slug" --json labels 2>/dev/null) || rc=$?
      tj=$("$self" issue view "$n" -R "$slug" --json title -q .title 2>/dev/null) || rc=$?
      [ "$rc" = 0 ] || { _gcr_send 500 '{}'; return 0; }
      out=$(jq -nc --arg t "$tj" --arg l "$lj" '{title:$t, labels:(($l|fromjson? // {})|.labels // [])}')
      _gcr_send 200 "$out"; return 0 ;;
    "DELETE repos/"*/labels/*)
      [ "$post" = 1 ] || return 1
      n="${p#*/issues/}"; n="${n%%/*}"
      if "$self" issue edit "$n" -R "$slug" --remove-label "${p##*/labels/}" >/dev/null 2>&1; then _gcr_send 200 '[]'
      else _gcr_send 500 '{}'; fi
      return 0 ;;
    "POST repos/"*/comments)
      [ "$post" = 1 ] || return 1
      n="${p#*/issues/}"; n="${n%%/*}"
      if "$self" issue comment "$n" -R "$slug" --body-file "${bf:-}" >/dev/null 2>&1; then _gcr_send 201 '{"id":1}'
      else _gcr_send 500 '{}'; fi
      return 0 ;;
  esac
  return 1
}

# gh_cli_rest_create <self> <args...> — BH-8962. Serves ONLY
# `api -X POST repos/S/issues` (no -i, no /issues/N suffix) from the stub's own
# `issue create` arm, whose output and rc it reads:
#   rc 0 + a /issues/<n> URL  -> {"number":n,"html_url":"<url>"} on stdout, rc 0
#   rc 0 + no URL             -> {} on stdout, rc 0 (the helper reads: no number)
#   rc != 0                   -> {"message":"<last line>"} on stdout,
#                                "gh: <last line> (HTTP 422)" on stderr, exit 1
#                                (the stub is a script: this IS gh's rc)
# Any other argv: rc 1, nothing printed, so the stub carries on as before.
gh_cli_rest_create() {
  # POSIX sh on purpose: a stub with no shebang line runs under /bin/sh when
  # timeout or env execs it, and an array here would stop dash from parsing
  # this whole file.
  local self="$1" slug title="" body="" prev="" a n out rc=0 url
  shift
  [ "${1:-}" = api ] && [ "${2:-}" = -X ] && [ "${3:-}" = POST ] || return 1
  case "${4:-}" in repos/*/*/issues) ;; *) return 1 ;; esac
  slug="${4#repos/}"; slug="${slug%/issues}"
  case "$slug" in */*/*) return 1 ;; esac
  shift 4
  n=$#
  for a in "$@"; do
    case "$prev" in
      -f) case "$a" in title=*) title="${a#title=}" ;; "labels[]="*) set -- "$@" --label "${a#labels\[\]=}" ;; esac ;;
      -F) case "$a" in body=@*) body="${a#body=@}" ;; esac ;;
    esac
    prev="$a"
  done
  shift "$n"
  out=$("$self" issue create -R "$slug" --title "$title" "$@" --body-file "$body" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    a=$(printf '%s\n' "$out" | tail -1)
    jq -nc --arg m "$a" '{message:$m}'
    echo "gh: $a (HTTP 422)" >&2
    exit 1
  fi
  url=$(printf '%s\n' "$out" | grep -oE 'https://[^ ]*/issues/[0-9]+' | tail -1)
  if [ -n "$url" ]; then
    jq -nc --arg u "$url" '{number:($u|capture("/issues/(?<n>[0-9]+)$").n|tonumber), html_url:$u}'
  else
    echo '{}'
  fi
  return 0
}
