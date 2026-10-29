#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/repo-detect-extra.sh — the four repo facts that join the
# repo-detect line (BH-7935.1). Sourced by repo-detect.sh, which merges the
# object over the base facts. Every GitHub access goes through the seam
# bin/lib/onboard-github.sh (og_get, og_clone); nothing here calls a vendor.
# owner BH-7935.1
#
# hp_repo_detect_extra <owner/repo>
#   Prints ONE JSON object with exactly four keys, rc 0 always (the base read
#   already decided pass or fail). A fact the seam cannot read is null, never a
#   guess:
#     ci_workflow      og_get .../actions/workflows: total_count > 0
#     package_manager  og_get .../contents (the root listing): the first FILE of
#                      package-lock.json npm, pnpm-lock.yaml pnpm, yarn.lock
#                      yarn, bun.lockb or bun.lock bun; else "none"
#     test_runner      no package.json file in the listing: "none" (no read).
#                      Else og_get .../contents/package.json, base64-decoded,
#                      scripts.test through _hp_rdx_test_runner
#     readiness_level  og_clone into a temp dir, then bin/readiness-report.sh
#                      <dir> --json --no-run with READINESS_GH=0 (the
#                      stranger's tests never run, GitHub is not asked), under
#                      the og_clone_timeout knob: its integer .level
#   The body runs in a subshell, so its EXIT trap removes the temp dir on every
#   path without touching the sourcing lane's own traps.
command -v og_get >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../onboard-github.sh"
_HP_RDX_REPORT="$(cd "${BASH_SOURCE[0]%/*}/../.." 2>/dev/null && pwd)/readiness-report.sh"

# _hp_rdx_test_runner <scripts.test>: vitest | jest | node --test | playwright
# | none. First match in that order; the npm placeholder is none.
_hp_rdx_test_runner() {
  local s="${1:-}" b='(^|[^A-Za-z0-9_-])' e='([^A-Za-z0-9_-]|$)'
  case "$s" in *"no test specified"*) echo none; return 0 ;; esac
  if [[ "$s" =~ ${b}vitest${e} ]]; then echo vitest
  elif [[ "$s" =~ ${b}jest${e} ]]; then echo jest
  elif [[ "$s" =~ ${b}node[[:space:]](.*[[:space:]])?--test([[:space:]=]|$) ]]; then echo "node --test"
  elif [[ "$s" =~ ${b}playwright${e} ]]; then echo playwright
  else echo none; fi
}

hp_repo_detect_extra() (
  slug="${1:-}" d="" ci=null pm=null tr=null lvl=null
  d=$(mktemp -d "${TMPDIR:-/tmp}/onb-clone.XXXXXX" 2>/dev/null) || d=""
  trap '[ -n "$d" ] && rm -rf "$d"' EXIT
  if body=$(og_get "repos/$slug/actions/workflows" 2>/dev/null); then
    ci=$(jq -c 'if (.total_count | type) == "number" then .total_count > 0 else null end' <<< "$body" 2>/dev/null) || ci=null
  fi
  if listing=$(og_get "repos/$slug/contents" 2>/dev/null) \
     && files=$(jq -r 'if type == "array" then .[] | select(.type == "file") | .name else error end' <<< "$listing" 2>/dev/null); then
    pm='"none"'
    for pair in package-lock.json:npm pnpm-lock.yaml:pnpm yarn.lock:yarn bun.lockb:bun bun.lock:bun; do
      if grep -qxF "${pair%%:*}" <<< "$files"; then pm="\"${pair##*:}\""; break; fi
    done
    if ! grep -qxF package.json <<< "$files"; then tr='"none"'
    elif body=$(og_get "repos/$slug/contents/package.json" 2>/dev/null) \
         && script=$(jq -er 'select(.encoding == "base64") | .content' <<< "$body" 2>/dev/null | base64 -d 2>/dev/null \
                     | jq -er 'if type == "object" then (.scripts.test // "") else error end' 2>/dev/null); then
      tr=$(jq -nc --arg r "$(_hp_rdx_test_runner "$script")" '$r')
    fi
  fi
  if [ -n "$d" ] && og_clone "$slug" "$d" >/dev/null 2>&1; then
    lvl=$(READINESS_GH=0 timeout "$(og_clone_timeout)" bash "$_HP_RDX_REPORT" "$d" --json --no-run 2>/dev/null \
      | jq -c '.level | select(type == "number" and . == floor)' 2>/dev/null)
    [ -n "$lvl" ] || lvl=null
  fi
  jq -nc --argjson c "$ci" --argjson p "$pm" --argjson t "$tr" --argjson l "$lvl" \
    '{ci_workflow:$c, package_manager:$p, test_runner:$t, readiness_level:$l}'
  return 0
)
