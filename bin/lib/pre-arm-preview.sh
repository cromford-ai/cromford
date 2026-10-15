#!/bin/bash
# bin/lib/pre-arm-preview.sh — the Vercel preview gate of bin/pre-arm-guards.sh.
#
# A gated repo's PR head whose own newest Vercel preview build is ERROR does
# not merge. project-3 merged 7 heads with a FAILED preview in 13 days, and each
# one turned the production build red and was reverted (#6160).
#
#   pap_knobs                         resolve the four knobs (settings row, env, code default)
#   pap_enabled <owner/repo>          rc 0 when the slug's fleet.conf project is gated
#   pap_head <owner/repo> <pr>        prints "<head-sha> <head-ref>"; rc 2 on a failed read
#   pap_check <owner/repo> <sha> <ref>
#                                     prints "<word>\t<detail>", rc 0 always; word is
#                                     off|exempt|blind|unseen|red|wait|pass
#
# The preview state is the file bin/vercel-deploy-snapshot.sh writes:
# state/vercel-deploys/<project>.json {generated_at, previews:[{sha,url,state,createdAt}]},
# else the copy pushed to boxes, state/vercel-deploy-status.json
# .projects[<project>].previews (the bin/wait-preview.sh order). No Vercel call.
# A snapshot the gate cannot read never holds a merge: it answers `blind`.
#
# Test seams: PAP_FLEET_CONF (fleet.conf), PAP_DIR (the state dir), PAP_NOW (epoch s).
# tests/pre-arm-preview.bh-6501-test.sh drives every row.

_PAP_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)

_pap_root() {
  local r="${HARNESS:-${H:-}}"
  [ -n "$r" ] || return 1
  printf '%s' "$r"
}

# _pap_project <owner/repo> — the fleet.conf project whose repo column is the slug.
_pap_project() {
  local conf="${PAP_FLEET_CONF:-}" r p
  if [ -z "$conf" ]; then r=$(_pap_root) || return 1; conf="$r/fleet.conf"; fi
  [ -r "$conf" ] || return 1
  p=$(awk -v s="${1:-}" '$1 !~ /^#/ && $2 == s {print $1; exit}' "$conf" 2>/dev/null)
  [ -n "$p" ] || return 1
  printf '%s' "$p"
}

# pap_knobs — lib_env_apply in a subshell (the bin/lib/build-tripwire.sh shape):
# its fail-closed exit cannot stop the caller. Every knob that is SET in the
# subshell comes back on fd 3, an empty value included, because an empty
# PRE_ARM_PREVIEW_PROJECTS means "gate no project".
pap_knobs() {
  local kv k s v
  kv=$(
    exec 3>&1
    command -v lib_env_apply >/dev/null 2>&1 || . "$_PAP_LIB/lane-gate.sh" >/dev/null 2>&1 || exit 0
    if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_PAP_LIB/lanes-registry.sh" >/dev/null 2>&1; then
      LANE_REGISTRY=$(lanes_json_path "$_PAP_LIB/../.." 2>/dev/null) && export LANE_REGISTRY
    fi
    trap 'for k in PRE_ARM_PREVIEW_PROJECTS PRE_ARM_PREVIEW_EXEMPT_BRANCHES PRE_ARM_PREVIEW_WAIT_MIN PRE_ARM_PREVIEW_STALE_MIN; do printf "%s\t%s\t%s\n" "$k" "${!k+set}" "${!k-}" >&3; done' EXIT
    lib_env_apply pre-arm-preview >/dev/null 2>&1) || true
  while IFS=$'\t' read -r k s v; do
    [ "$s" = set ] || continue
    case "$k" in
      PRE_ARM_PREVIEW_PROJECTS|PRE_ARM_PREVIEW_EXEMPT_BRANCHES|PRE_ARM_PREVIEW_WAIT_MIN|PRE_ARM_PREVIEW_STALE_MIN)
        export "$k=$v" ;;
    esac
  done <<<"$kv"
  return 0
}

# _pap_int <value> <default> — the value when it is a whole number, else the default.
_pap_int() {
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$((10#$1))" ;; esac
}

# pap_enabled <owner/repo> — row 1 of pap_check alone: a fleet.conf read, no gh call.
pap_enabled() {
  local p w list
  p=$(_pap_project "${1:-}") || return 1
  read -ra list <<<"${PRE_ARM_PREVIEW_PROJECTS-project-3}"
  for w in ${list[@]+"${list[@]}"}; do
    [ "$w" = "$p" ] && return 0
  done
  return 1
}

# pap_head <owner/repo> <pr> — one REST read of the PR. Needs gh_rest_var
# (bin/lib/gh-rest-var.sh, loaded by bin/lib/gh-rest.sh): a gh_rest inside
# `$( )` loses GH_REST_STATUS (tests/gh-rest-no-subshell-lint.sh).
pap_head() {
  local body="" sha ref
  command -v gh_rest_var >/dev/null 2>&1 || return 2
  gh_rest_var body GET "repos/${1:-}/pulls/${2:-}" 2>/dev/null || return 2
  sha=$(jq -r '.head.sha // empty' <<<"$body" 2>/dev/null)
  ref=$(jq -r '.head.ref // empty' <<<"$body" 2>/dev/null)
  [ -n "$sha" ] || return 2
  printf '%s %s\n' "$sha" "$ref"
}

# pap_check <owner/repo> <head-sha> <head-ref> — first matching row wins:
#   1 project not gated, or slug not in fleet.conf      off
#   2 ref matches a PRE_ARM_PREVIEW_EXEMPT_BRANCHES glob exempt  <glob>
#   3 head is not 40 hex chars                          blind   no head sha
#   4 no snapshot, not JSON, or no generated_at         blind   snapshot unreadable
#   5 generated_at older than PRE_ARM_PREVIEW_STALE_MIN blind   snapshot <n>m old
#   6 no preview row for the exact head sha             unseen
#   7 the head's newest row (max createdAt) is ERROR    red     Vercel preview ERROR on <head12> (<url>)
#   8 newest row BUILDING/QUEUED/INITIALIZING, numeric createdAt,
#     younger than PRE_ARM_PREVIEW_WAIT_MIN minutes     wait    Vercel preview <state> on <head12> for <n>m
#   9 anything else                                     pass    <state>
pap_check() {
  local slug="${1:-}" head="${2:-}" ref="${3:-}" p g list now stale wait dir src gen age row st url ca w
  p=$(_pap_project "$slug") || { printf 'off\t-\n'; return 0; }
  pap_enabled "$slug" || { printf 'off\t-\n'; return 0; }

  read -ra list <<<"${PRE_ARM_PREVIEW_EXEMPT_BRANCHES-rollback/* revert-*}"
  for g in ${list[@]+"${list[@]}"}; do
    # shellcheck disable=SC2254 # the glob is the point
    case "$ref" in $g) printf 'exempt\t%s\n' "$g"; return 0 ;; esac
  done

  [[ "$head" =~ ^[0-9a-fA-F]{40}$ ]] || { printf 'blind\tno head sha\n'; return 0; }
  head=$(printf '%s' "$head" | tr '[:upper:]' '[:lower:]')

  now="${PAP_NOW:-$(date -u +%s)}"
  stale=$(_pap_int "${PRE_ARM_PREVIEW_STALE_MIN:-}" 30)
  wait=$(_pap_int "${PRE_ARM_PREVIEW_WAIT_MIN:-}" 20)
  dir="${PAP_DIR:-}"
  if [ -z "$dir" ]; then dir=$(_pap_root) && dir="$dir/state" || dir=""; fi

  src=""
  if [ -n "$dir" ] && [ -s "$dir/vercel-deploys/$p.json" ]; then
    src=$(jq -c 'select(type == "object" and (.generated_at | type) == "string")
                 | {g: .generated_at, rows: (.previews // [])}' "$dir/vercel-deploys/$p.json" 2>/dev/null) || src=""
  fi
  if [ -z "$src" ] && [ -n "$dir" ] && [ -s "$dir/vercel-deploy-status.json" ]; then
    src=$(jq -c --arg p "$p" 'select(type == "object" and (.generated_at | type) == "string")
                 | {g: .generated_at, rows: (.projects[$p].previews // [])}' "$dir/vercel-deploy-status.json" 2>/dev/null) || src=""
  fi
  [ -n "$src" ] || { printf 'blind\tsnapshot unreadable\n'; return 0; }
  gen=$(date -u -d "$(jq -r '.g' <<<"$src")" +%s 2>/dev/null) || gen=""
  [ -n "$gen" ] || { printf 'blind\tsnapshot unreadable\n'; return 0; }
  age=$(( now - gen ))
  [ "$age" -gt $(( stale * 60 )) ] && { printf 'blind\tsnapshot %sm old\n' "$(( age / 60 ))"; return 0; }

  # The head's newest row; on a createdAt tie ERROR sorts last, so it wins.
  row=$(jq -r --arg h "$head" '
      [ (.rows // [])[]? | select(type == "object" and ((.sha // "") | tostring | ascii_downcase) == $h)
        | {st: ((.state // "") | tostring | ascii_upcase), url: ((.url // "") | tostring),
           ca: (if (.createdAt | type) == "number" then .createdAt else null end)} ]
      | sort_by([(.ca // 0), (if .st == "ERROR" then 1 else 0 end)]) | last
      | if . == null then empty else [.st, .url, (if .ca == null then "-" else (.ca | floor | tostring) end)] | @tsv end
    ' <<<"$src" 2>/dev/null)
  [ -n "$row" ] || { printf 'unseen\t-\n'; return 0; }
  IFS=$'\t' read -r st url ca <<<"$row"

  case "$st" in
    ERROR) printf 'red\tVercel preview ERROR on %s (%s)\n' "${head:0:12}" "${url:--}"; return 0 ;;
    BUILDING|QUEUED|INITIALIZING)
      if [ "$ca" != - ]; then
        w=$(( now * 1000 - ca ))
        if [ "$w" -lt $(( wait * 60000 )) ]; then
          [ "$w" -lt 0 ] && w=0
          printf 'wait\tVercel preview %s on %s for %sm\n' "$st" "${head:0:12}" "$(( w / 60000 ))"; return 0
        fi
      fi ;;
  esac
  printf 'pass\t%s\n' "${st:--}"
  return 0
}
