#!/bin/bash
# gh-identity: app-token
# shellcheck shell=bash
# bin/lib/revert-reason.sh — why a merge was reverted. Sourced, never run.
#
# A revert on main says THAT a merge came back out, never WHY. This lib finds
# the reverts on a project's default branch, reads the failure signal around
# each one from GitHub and the ledger, and saves it where the ticket's rebuild
# reads it:
#   ledger row  kind revert_reason, key "<project> <KEY>" (a PR with no ticket
#               key: "<project> #<pr>"), status saved | no-signal | unreadable,
#               detail = the v1 JSON below. A build on any box reads it.
#   mirror      $HARNESS/state/revert-reasons/<project>/<safe-key>.json, the
#               same JSON plus {status, ledger}.
#   index       $HARNESS/state/revert-reasons/<project>/index.tsv, one line per
#               revert commit: revert_sha, at, status, attempts, keys, classes.
#               The dedup and retry record, and the weekly line's source.
# Detail v1:
#   {"v":1,"project","key","at":"<capture ISO>","reverts":[{"revert_sha",
#    "revert_pr","merged_pr","merge_sha","kind":"revert"|"rollback","at",
#    "status","attempts","classes":[...],"signals":[{"class","source","text","url"}]}]}
#   Newest 3 reverts, newest first, cut to 3800 bytes by dropping the oldest
#   signal first.
# Signal classes:
#   build   a failed commit status or check run on the reverted merge commit
#   probe   a deploy_rollback ledger row (bin/deploy-rollback-board.sh) for the
#           merge, or the deploy-train rollback PR's own first line
#   stated  the revert PR's body and its comments, bots and footers dropped
#
# Readers: rv_plan_line (bin/lib/rb/plan.sh, the build plan prompt) and
# rv_week_line (bin/lookback.sh, the weekly summary). Writer: rv_capture, called
# by bin/reopen-metrics.sh per project, and rv_capture_report once per run.
# Read only toward GitHub and the boards: no comment, no status change.
#
# FAIL-OPEN, every function. No jobs client, no row, an outage or a bad JSON
# returns non-zero or prints nothing, and the caller carries on as before.
# Knobs (catalog/lanes.d/_lib.revert-reason.json), read through lane-gate's
# lib_env_apply revert-reason, then env, then the default:
#   REVERT_REASON (1), REVERT_REASON_LOOKBACK_D (7), REVERT_REASON_PAGES (3),
#   REVERT_REASON_MAX_COMMENTS (3), REVERT_REASON_MAX_PER_RUN (20),
#   REVERT_REASON_MAX_AGE_D (30).
# Clock seam for tests: RV_NOW (epoch seconds).
#
# The harness root is ${HARNESS:-${H:-}} and nothing else (BH-2613).

RV__KNOBS="REVERT_REASON REVERT_REASON_LOOKBACK_D REVERT_REASON_PAGES REVERT_REASON_MAX_COMMENTS REVERT_REASON_MAX_PER_RUN REVERT_REASON_MAX_AGE_D"

rv__root() { local r="${HARNESS:-${H:-}}"; [ -n "$r" ] || return 1; printf '%s' "$r"; }
rv__now() { if [[ "${RV_NOW:-}" =~ ^[0-9]+$ ]]; then printf '%s' "$RV_NOW"; else date -u +%s; fi; }

# rv__env — apply the operator rows for this lib once per shell.
rv__env() {
  [ -n "${RV__ENV_DONE:-}" ] && return 0
  RV__ENV_DONE=1
  local lib out n v
  rv__root >/dev/null || return 0
  lib=$(dirname "${BASH_SOURCE[0]}")
  out=$(
    command -v lib_env_apply >/dev/null 2>&1 || . "$lib/lane-gate.sh" >/dev/null 2>&1
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply revert-reason >/dev/null 2>&1
    for n in $RV__KNOBS; do printf '%s=%s\n' "$n" "${!n:-}"; done
  ) 2>/dev/null
  while IFS='=' read -r n v; do
    [ -n "$n" ] && [ -n "$v" ] && printf -v "$n" '%s' "$v"
  done <<<"$out"
  return 0
}

# rv__int <NAME> <default> — the knob as a non-negative integer, else the default.
rv__int() {
  local v="${!1:-}"
  [[ "$v" =~ ^[0-9]+$ ]] || v="$2"
  printf '%s' "$v"
}

rv_on() { rv__env; [ "${REVERT_REASON:-1}" != 0 ]; }

rv_safe_key() { printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '_'; }

rv__dir() { # rv__dir <p> -> the project's state dir
  local r; r=$(rv__root) || return 1
  printf '%s/state/revert-reasons/%s' "$r" "$(rv_safe_key "$1")"
}
rv__mirror() { local d; d=$(rv__dir "$1") || return 1; printf '%s/%s.json' "$d" "$(rv_safe_key "$2")"; }

# rv_since_iso — now minus REVERT_REASON_LOOKBACK_D days, ISO 8601 UTC.
rv_since_iso() {
  local d
  rv__env
  d=$(rv__int REVERT_REASON_LOOKBACK_D 7)
  jq -nr --argjson t "$(rv__now)" --argjson d "$d" '$t - $d * 86400 | todate'
}

# rv_parse_subject <subject> -> "<kind>\t<N>\t<M>", rc 0; rc 1 for any other subject.
#   Revert "<anything> (#N)" (#M)            -> revert  N M
#   Revert "<anything> (#N)"                 -> revert  N ""
#   Revert "Merge pull request #N from ..."  -> revert  N ""   (plus (#M) if present)
#   Rollback: revert failed deploy batch (...) (#M) -> rollback "" M
# N is the PR the revert took out. A revert of a revert names the inner revert PR.
rv_parse_subject() {
  local s="${1:-}" inner="" m="" n=""
  if [[ "$s" =~ ^Rollback:\ revert\ failed\ deploy\ batch\ \(.*\)\ \(#([0-9]+)\)$ ]]; then
    printf 'rollback\t\t%s\n' "${BASH_REMATCH[1]}"; return 0
  fi
  [[ "$s" =~ ^Revert\ \"(.*)\"$ ]] && inner="${BASH_REMATCH[1]}"
  if [ -z "$inner" ] && [[ "$s" =~ ^Revert\ \"(.*)\"\ \(#([0-9]+)\)$ ]]; then
    inner="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
  fi
  [ -n "$inner" ] || return 1
  if [[ "$inner" =~ ^Merge\ pull\ request\ #([0-9]+)\ from\  ]]; then n="${BASH_REMATCH[1]}"
  elif [[ "$inner" =~ \(#([0-9]+)\)$ ]]; then n="${BASH_REMATCH[1]}"
  else return 1; fi
  printf 'revert\t%s\t%s\n' "$n" "$m"
}

# rv_ticket_key <head-branch> <title> -> the ticket KEY, uppercased, or nothing.
#   ticket/<key> or ticket/<key>-r<n>  (ticket/TK-271 -> TK-271), nothing else:
#   another suffix (ticket/bh-1486-local) is not a ticket branch
#   (tests/ticket-branch-ratchet.bh-3835-test.sh)
#   else a last word <letters>-<digits> in the title before an optional (#N)
rv_ticket_key() {
  local b="${1:-}" t="${2:-}"
  if [[ "$b" =~ ^ticket/([A-Za-z]+-[0-9]+)(-r[0-9]+)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]^^}"; return 0
  fi
  t="${t% }"
  [[ "$t" =~ ^(.*[^ ])\ \(#[0-9]+\)$ ]] && t="${BASH_REMATCH[1]}"
  if [[ "$t" =~ (^|[ ])([A-Za-z]{1,8}-[0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[2]^^}"; return 0
  fi
  return 0
}

# ---------------------------------------------------------------- the capture

rv__run_file() { local d="${RV_RUN:-${RR_RUN:-}}"; [ -n "$d" ] && [ -d "$d" ] && printf '%s/rv-%s' "$d" "$1"; }

# rv__gh <path> <out> — one REST read into <out>; rc 0 only for a 2xx JSON body.
rv__gh() {
  local rc=0
  command -v gh_rest >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" 2>/dev/null
  command -v gh_rest >/dev/null 2>&1 || return 75
  gh_rest GET "$1" > "$2" 2>/dev/null || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  jq -e . "$2" >/dev/null 2>&1 || return 75
}

# rv__build_signals <slug> <merge_sha> <tmpdir> -> JSON array; rc 1 on a failed read.
rv__build_signals() {
  local slug="$1" sha="$2" t="$3" a b
  [ -n "$sha" ] || { printf '[]'; return 0; }
  rv__gh "repos/$slug/commits/$sha/status" "$t/st.json" || return 1
  rv__gh "repos/$slug/commits/$sha/check-runs?per_page=100" "$t/cr.json" || return 1
  a=$(jq -c '[.statuses[]? | select(.state == "failure" or .state == "error")
      | {class:"build", source:(.context // "status"), text:((.description // .state) | tostring | .[0:500]), url:(.target_url // "")}]' "$t/st.json") || return 1
  b=$(jq -c '[.check_runs[]? | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled")
      | {class:"build", source:(.name // "check"), text:((.output.title // .conclusion) | tostring | .[0:500]), url:(.html_url // "")}]' "$t/cr.json") || return 1
  jq -nc --argjson a "$a" --argjson b "$b" '$a + $b'
}

# rv__probe_signals <p> <KEY> <merge_sha> -> JSON array from the BH-4915
# deploy_rollback row "<p> <KEY>@<sha8>"; rc 1 when the ledger did not answer.
# No jobs client, no key or no sha: [] (the source does not exist here).
rv__probe_signals() {
  local p="$1" k="$2" sha="$3" row rc=0
  if [ -z "$k" ] || [ -z "$sha" ] || ! command -v job_ledger_row >/dev/null 2>&1; then printf '[]'; return 0; fi
  row=$(job_ledger_row deploy_rollback "$p $k@${sha:0:8}" 2>/dev/null) || rc=$?
  case "$rc" in
    0) jq -c '(.detail | if type == "string" then (try fromjson catch {}) else . end | if type == "object" then . else {} end) as $d
         | if ($d.reason // "") == "" then [] else
             [{class:"probe", source:"deploy_rollback", text:($d.reason | tostring | .[0:500]), url:($d.revert_pr // "")}] end' <<<"$row" 2>/dev/null || printf '[]' ;;
    2) printf '[]' ;;
    *) return 1 ;;
  esac
}

# rv__stated_signals <slug> <M> <tmpdir> -> JSON array from revert PR #M's body
# and comments; rc 1 on a failed read. Dropped: bot authors, the attribution
# footer, GitHub's "Reverts owner/repo#N" line, empty text.
rv__stated_signals() {
  local slug="$1" m="$2" t="$3" n
  [ -n "$m" ] || { printf '[]'; return 0; }
  rv__env
  n=$(rv__int REVERT_REASON_MAX_COMMENTS 3)
  rv__gh "repos/$slug/pulls/$m" "$t/rp.json" || return 1
  rv__gh "repos/$slug/issues/$m/comments?per_page=100" "$t/rc.json" || return 1
  jq -nc --argjson n "$n" --arg m "$m" --slurpfile pr "$t/rp.json" --slurpfile cs "$t/rc.json" '
    def bot: ((.user.type // "") == "Bot") or ((.user.login // "") | endswith("[bot]"));
    def clean: (. // "") | tostring | split("\n")
      | map(select(test("^\\s*(🤖 Generated with|Co-Authored-By:|Reverts [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\\s*$)") | not))
      | join(" ") | gsub("<[^>]*>"; " ") | gsub("\\s+"; " ") | sub("^ +"; "") | sub(" +$"; "");
    ([$pr[0] | select(bot | not) | {at:(.created_at // ""), source:"revert PR #\($m) body", text:(.body | clean), url:(.html_url // "")}]
     + [$cs[0][]? | select(bot | not) | {at:(.created_at // ""), source:"comment by \(.user.login // "unknown")", text:(.body | clean), url:(.html_url // "")}])
    | map(select(.text != "")) | sort_by(.at) | .[(if length > $n then length - $n else 0 end):] | reverse
    | map({class:"stated", source, text:(.text[0:500]), url})'
}

# rv__member <status> <key> <merged_pr> <merge_sha> <signals-json> -> one member JSON line
rv__member() {
  jq -nc --arg s "$1" --arg k "$2" --arg n "$3" --arg h "$4" --argjson g "${5:-[]}" \
    '{status:$s, key:$k, merged_pr:$n, merge_sha:$h, signals:$g}'
}

# rv__read_revert <p> <slug> <kind> <N> <M> <tmpdir> — the reads for one revert.
# Prints one member JSON line per ticket the revert took out. A key-less PR
# gets key "#<N>"; a rollback member with no PR gets its sha8. Prints nothing
# and rc 1 when the read that names the members failed.
rv__read_revert() {
  local p="$1" slug="$2" kind="$3" n="$4" m="$5" t="$6"
  local key msha sigs b pr st body first sha hs ro=ok
  if [ "$kind" = revert ]; then
    rv__gh "repos/$slug/pulls/$n" "$t/pr.json" || return 1
    IFS=$'\x1f' read -r hs msha < <(jq -r '[.head.ref // "", .merge_commit_sha // ""] | join("\u001f")' "$t/pr.json")
    key=$(rv_ticket_key "$hs" "$(jq -r '.title // ""' "$t/pr.json")")
    sigs='[]'
    b=$(rv__build_signals "$slug" "$msha" "$t") && sigs=$(jq -c --argjson b "$b" '. + $b' <<<"$sigs") || ro=unreadable
    if [ -n "$key" ]; then
      b=$(rv__probe_signals "$p" "$key" "$msha") && sigs=$(jq -c --argjson b "$b" '. + $b' <<<"$sigs") || ro=unreadable
    fi
    b=$(rv__stated_signals "$slug" "$m" "$t") && sigs=$(jq -c --argjson b "$b" '. + $b' <<<"$sigs") || ro=unreadable
    if [ "$ro" = unreadable ]; then st=unreadable
    elif [ "$(jq length <<<"$sigs")" -gt 0 ]; then st=saved
    else st=no-signal; fi
    rv__member "$st" "${key:-#$n}" "$n" "$msha" "$sigs"
    return 0
  fi
  # rollback: the PR body lists the merges it reverted.
  rv__gh "repos/$slug/pulls/$m" "$t/rb.json" || return 1
  body=$(jq -r '.body // ""' "$t/rb.json")
  first=$(printf '%s\n' "$body" | sed -n '/[^[:space:]]/{p;q;}' | cut -c1-500)
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    ro=ok; key=""; pr=""
    if rv__gh "repos/$slug/commits/$sha/pulls" "$t/cp.json"; then
      IFS=$'\x1f' read -r pr hs < <(jq -r '(.[0] // {}) | [(.number // "" | tostring), .head.ref // ""] | join("\u001f")' "$t/cp.json")
      key=$(rv_ticket_key "$hs" "$(jq -r '(.[0] // {}).title // ""' "$t/cp.json")")
    else
      ro=unreadable
    fi
    sigs='[]'
    if [ -n "$key" ]; then
      b=$(rv__probe_signals "$p" "$key" "$sha") && sigs="$b" || ro=unreadable
    fi
    if [ "$(jq length <<<"$sigs")" = 0 ] && [ -n "$first" ]; then
      sigs=$(jq -nc --arg x "$first" --arg u "$(jq -r '.html_url // ""' "$t/rb.json")" '[{class:"probe", source:"rollback PR body", text:$x, url:$u}]')
    fi
    if [ "$ro" = unreadable ]; then st=unreadable
    elif [ "$(jq length <<<"$sigs")" -gt 0 ]; then st=saved
    else st=no-signal; fi
    if [ -z "$key" ]; then key="${pr:+#$pr}"; key="${key:-${sha:0:8}}"; fi
    rv__member "$st" "$key" "$pr" "$sha" "$sigs"
  done < <(printf '%s\n' "$body" | sed -n 's/^Reverted:[[:space:]]*//p' | grep -oE '\b[0-9a-f]{7,40}\b')
  return 0
}

# rv_encode <p> <key> <reverts-json> -> detail v1, at most 3800 bytes; the
# oldest signal (last revert's last signal) is dropped first.
rv_encode() {
  local rj="$3" out
  jq -e 'type == "array"' <<<"$rj" >/dev/null 2>&1 || rj='[]'
  rj=$(jq -c 'sort_by(.at) | reverse | .[:3]' <<<"$rj")
  while :; do
    out=$(jq -nc --arg p "$1" --arg k "$2" --argjson now "$(rv__now)" --argjson r "$rj" \
      '{v:1, project:$p, key:$k, at:($now | todate), reverts:$r}') || return 1
    [ "$(printf '%s' "$out" | LC_ALL=C wc -c)" -le 3800 ] && break
    [ "$(jq '[.[].signals | length] | add // 0' <<<"$rj")" -gt 0 ] || break
    rj=$(jq -c '(map(.signals | length > 0) | rindex(true)) as $i | .[$i].signals |= .[:-1]' <<<"$rj")
  done
  printf '%s' "$out"
}

# rv__status_of <detail> -> saved | no-signal | unreadable (over its reverts)
rv__status_of() {
  jq -r '[.reverts[]?.status] as $s
    | if any($s[]; . == "saved") then "saved" elif any($s[]; . == "unreadable") then "unreadable" else "no-signal" end' <<<"$1" 2>/dev/null
}

rv__mirror_write() { # <path> <detail> <status> <true|false>
  jq -c --arg s "$3" --argjson l "$4" '. + {status:$s, ledger:$l}' <<<"$2" > "$1.tmp" 2>/dev/null \
    && mv -f "$1.tmp" "$1" || { rm -f "$1.tmp"; return 1; }
}

# rv_save <p> <key> <status> <detail> — mirror ({ledger:false}), then the
# ledger row, then the mirror with ledger:true. rc 1 = the ledger did not take it.
rv_save() {
  local p="$1" k="$2" st="$3" d="$4" m
  m=$(rv__mirror "$p" "$k") || return 1
  mkdir -p "$(dirname "$m")" 2>/dev/null || return 1
  rv__mirror_write "$m" "$d" "$st" false || return 1
  if command -v job_ledger_put >/dev/null 2>&1 && job_ledger_put revert_reason "$p $k" "$st" "$d" >/dev/null 2>&1; then
    rv__mirror_write "$m" "$d" "$st" true
    return 0
  fi
  return 1
}

# rv__index_set <p> <revert_sha> <at> <status> <attempts> <keys> <classes>
rv__index_set() {
  local d f
  d=$(rv__dir "$1") || return 1
  f="$d/index.tsv"
  mkdir -p "$d" 2>/dev/null || return 1
  { awk -F'\t' -v s="$2" '$1 != s' "$f" 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "${6:--}" "${7:--}"; } > "$f.tmp" \
    && mv -f "$f.tmp" "$f"
}

# rv__results <status> <p> <revert_sha8> <ok|ledger-failed|-> <attempts> <keys>
rv__results() {
  local res; res=$(rv__run_file results.tsv) || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$res"
}

# rv_capture <p> <slug> <since-iso> — the revert pass for one project.
#   1. Re-put every mirror the ledger missed (no GitHub read).
#   2. List the default branch's commits since <since-iso>
#      (REVERT_REASON_PAGES pages of 100), keep the revert subjects.
#   3. Skip a revert the index holds as saved or no-signal, or as unreadable
#      after 3 tries. Read the rest, up to REVERT_REASON_MAX_PER_RUN per run
#      fleet-wide; over the cap a revert is counted "left" and read next run.
#   4. Save one row per ticket (merging with the reverts it already holds) and
#      one index line per revert.
# Results go to $RV_RUN (or $RR_RUN)/rv-results.tsv for rv_capture_report.
rv_capture() {
  local p="$1" slug="$2" since="$3" dir t page pages cap used rc
  local sha at subj kind n m prev patt att mem k st det rd keys cls ist mf
  rv_on || return 0
  dir=$(rv__dir "$p") || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  [ -f "$dir/index.tsv" ] || : > "$dir/index.tsv"
  # 1. ledger misses
  for mf in "$dir"/*.json; do
    [ -f "$mf" ] || continue
    [ "$(jq -r '.ledger | tostring' "$mf" 2>/dev/null)" = false ] || continue
    k=$(jq -r '.key // ""' "$mf"); st=$(jq -r '.status // ""' "$mf")
    [ -n "$k" ] && [ -n "$st" ] || continue
    if command -v job_ledger_put >/dev/null 2>&1 \
       && job_ledger_put revert_reason "$p $k" "$st" "$(jq -c 'del(.status, .ledger)' "$mf")" >/dev/null 2>&1; then
      jq -c '.ledger = true' "$mf" > "$mf.tmp" 2>/dev/null && mv -f "$mf.tmp" "$mf"
      rv__results reput "$p" - ok 0 "$k"
    else
      rv__results reput "$p" - ledger-failed 0 "$k"
    fi
  done
  # 2. the commit list
  t=$(mktemp -d) || return 1
  pages=$(rv__int REVERT_REASON_PAGES 3)
  cap=$(rv__int REVERT_REASON_MAX_PER_RUN 20)
  : > "$t/reverts.tsv"
  command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$slug" || true; }
  page=1; rc=0
  while [ "$page" -le "$pages" ]; do
    rv__gh "repos/$slug/commits?since=$since&per_page=100&page=$page" "$t/c.json" || { rc=1; break; }
    jq -r '.[]? | [.sha // "", (.commit.committer.date // .commit.author.date // ""), ((.commit.message // "") | split("\n")[0])] | @tsv' \
      "$t/c.json" >> "$t/reverts.tsv"
    [ "$(jq 'length' "$t/c.json")" -ge 100 ] || break
    page=$((page + 1))
  done
  if [ "$rc" != 0 ]; then
    att=$(( $(cat "$dir/list-fail.n" 2>/dev/null || echo 0) + 1 ))
    echo "$att" > "$dir/list-fail.n"
    rv__results list-unreadable "$p" - - "$att" "$slug"
    command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
    rm -rf "$t"; return 0
  fi
  rm -f "$dir/list-fail.n"
  # 3. each revert, oldest first
  while IFS=$'\t' read -r sha at subj; do
    [ -n "$sha" ] || continue
    kind=""; n=""; m=""; prev=""; patt=0
    IFS=$'\x1f' read -r kind n m < <(rv_parse_subject "$subj" | tr '\t' '\037') || continue
    [ -n "$kind" ] || continue
    IFS=$'\t' read -r prev patt < <(awk -F'\t' -v s="$sha" '$1 == s {print $3 "\t" $4}' "$dir/index.tsv")
    [[ "${patt:-}" =~ ^[0-9]+$ ]] || patt=0
    case "${prev:-}" in
      saved|no-signal) continue ;;
      unreadable) [ "$patt" -ge 3 ] && continue ;;
    esac
    att=$((patt + 1))
    used=$(grep -c . "$(rv__run_file cap.n)" 2>/dev/null || true); used=${used:-0}
    if [ "$used" -ge "$cap" ]; then rv__results left "$p" "${sha:0:8}" - 0 -; continue; fi
    echo x >> "$(rv__run_file cap.n)"
    : > "$t/members.jsonl"
    if ! rv__read_revert "$p" "$slug" "$kind" "$n" "$m" "$t" > "$t/members.jsonl"; then
      rv__index_set "$p" "$sha" "$at" unreadable "$att" - -
      rv__results unreadable "$p" "${sha:0:8}" - "$att" -
      continue
    fi
    rd=ok; keys=""; cls=""
    while IFS= read -r mem; do
      [ -n "$mem" ] || continue
      k=$(jq -r '.key' <<<"$mem")
      mf=$(rv__mirror "$p" "$k") || continue
      det=$(jq -c --arg sha "$sha" --arg at "$at" --arg kind "$kind" --arg m "$m" --argjson att "$att" --argjson mem "$mem" \
        --slurpfile old <( [ -s "$mf" ] && cat "$mf" || echo '{}') -n '
        ($old[0].reverts // []) | map(select(.revert_sha != $sha))
        + [{revert_sha:$sha, revert_pr:$m, merged_pr:$mem.merged_pr, merge_sha:$mem.merge_sha, kind:$kind, at:$at,
            status:$mem.status, attempts:$att, classes:($mem.signals | map(.class) | unique), signals:$mem.signals}]')
      det=$(rv_encode "$p" "$k" "$det") || continue
      st=$(rv__status_of "$det")
      rv_save "$p" "$k" "$st" "$det" || rd=ledger-failed
      keys="${keys:+$keys,}$k"
      cls="${cls:+$cls,}$(jq -r '.signals | map(.class) | unique | join(",")' <<<"$mem")"
    done < "$t/members.jsonl"
    ist=$(jq -rs 'map(.status) as $s | if length == 0 then "no-signal"
      elif any($s[]; . == "unreadable") then "unreadable" elif any($s[]; . == "saved") then "saved" else "no-signal" end' "$t/members.jsonl")
    cls=$(tr ',' '\n' <<<"$cls" | grep . | sort -u | paste -sd, -)
    rv__index_set "$p" "$sha" "$at" "$ist" "$att" "${keys:--}" "${cls:--}"
    # the status said in the run line is the one the index now holds
    ist=$(awk -F'\t' -v s="$sha" '$1 == s {print $3}' "$dir/index.tsv")
    rv__results "${ist:-unreadable}" "$p" "${sha:0:8}" "$rd" "$att" "${keys:--}"
  done < <(tac "$t/reverts.tsv")
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  rm -rf "$t"
  return 0
}

# rv_capture_report — the run's one lane-log line, and at most three ALERTS
# lines: reverts that reached 3 unreadable tries THIS run, repos whose commit
# list failed 3 runs in a row, and rows the ledger did not take.
rv_capture_report() {
  local res r a b c d k cap three lst nol
  rv__env
  cap=$(rv__int REVERT_REASON_MAX_PER_RUN 20)
  res=$(rv__run_file results.tsv) || return 0
  [ -f "$res" ] || : > "$res"
  a=$(awk -F'\t' '$1=="saved"' "$res" | grep -c .)
  b=$(awk -F'\t' '$1=="no-signal"' "$res" | grep -c .)
  c=$(awk -F'\t' '$1=="unreadable"' "$res" | grep -c .)
  d=$(awk -F'\t' '$1=="left"' "$res" | grep -c .)
  k=$(awk -F'\t' '$4=="ledger-failed"' "$res" | grep -c .)
  lst=$(awk -F'\t' '$1=="list-unreadable" {print $2}' "$res" | paste -sd, - | sed 's/,/, /g')
  echo "revert reasons: $a saved, $b no-signal, $c unreadable, $d left for the next run (cap $cap)$([ "$k" -gt 0 ] && echo " ($k not in the ledger)")$([ -n "$lst" ] && echo " (commit list unreadable: $lst)")"
  r=$(rv__root) || return 0
  three=$(awk -F'\t' '$1=="unreadable" && $5=="3" {print $2" "$3}' "$res" | paste -sd, - | sed 's/,/, /g')
  [ -z "$three" ] || HARNESS="$r" "$r/bin/alert-line.sh" "[reopen-metrics] revert reason not saved after 3 tries for: $three — read the revert PR by hand"
  three=$(awk -F'\t' '$1=="list-unreadable" && $5=="3" {print $2" ("$6")"}' "$res" | paste -sd, - | sed 's/,/, /g')
  [ -z "$three" ] || HARNESS="$r" "$r/bin/alert-line.sh" "[reopen-metrics] revert reason: commit list unreadable 3 runs in a row for: $three — check the hub token's read access to the repo"
  nol=$(awk -F'\t' '$4=="ledger-failed" {print $2" "$6}' "$res" | sort -u | paste -sd, - | sed 's/,/, /g')
  [ -z "$nol" ] || HARNESS="$r" "$r/bin/alert-line.sh" "[reopen-metrics] revert reason saved on the hub only, not in the ledger, for: $nol — a watcher-box build cannot see it; see logs/jobs-client.log"
  return 0
}

# ---------------------------------------------------------------- the readers

rv__valid() { jq -e 'type == "object" and .v == 1 and (.key | type) == "string" and (.reverts | type) == "array"' <<<"${1:-}" >/dev/null 2>&1; }

# rv__get1 <p> <key> -> sets RV_DETAIL RV_SRC; rc 0 found, 2 none, 1 ledger unreadable and no mirror.
rv__get1() {
  local p="$1" k="$2" row rc=2 d m
  if command -v job_ledger_row >/dev/null 2>&1; then
    row=$(job_ledger_row revert_reason "$p $k" 2>/dev/null); rc=$?
    if [ "$rc" = 0 ]; then
      d=$(jq -r '.detail // ""' <<<"$row" 2>/dev/null)
      if rv__valid "$d"; then RV_DETAIL=$(jq -c . <<<"$d"); RV_SRC=ledger; return 0; fi
      rc=1
    fi
  else
    rc=1
  fi
  m=$(rv__mirror "$p" "$k") || return 1
  if [ -s "$m" ] && rv__valid "$(cat "$m")"; then RV_DETAIL=$(jq -c 'del(.status, .ledger)' "$m"); RV_SRC=mirror; return 0; fi
  [ "$rc" = 1 ] && return 1
  return 2
}

# rv_plan_line <p> <KEY> — prints the plan prompt text for a ticket whose merge
# was reverted, or nothing. Sets RV_LINE and RV_LOG in the caller's shell (call
# it directly, not in $(...), to read RV_LOG): "saved <n> revert(s) <classes>",
# "none", "none (no signal)", "none (unreadable row)", "old (<n> d)", "off" or
# "unreadable". A BH-<n> key on a GitHub-Issues project also tries "#<n>".
rv_plan_line() {
  local p="${1:-}" k="${2:-}" rc rc2 d at now maxd n cls body hex fc bp line=""
  RV_LINE=""; RV_LOG=none; RV_DETAIL=""; RV_SRC=""
  rv_on || { RV_LOG=off; return 0; }
  [ -n "$p" ] && [ -n "$k" ] || return 0
  rv__get1 "$p" "$k"; rc=$?
  if [ "$rc" != 0 ] && [[ "$k" =~ ^[A-Za-z]+-([0-9]+)$ ]]; then
    fc="$(dirname "${BASH_SOURCE[0]}")/../fleet-conf.sh"
    bp=$("$fc" "$p" board_prefix 2>/dev/null)
    if [ "$bp" = "-" ]; then
      rv__get1 "$p" "#${BASH_REMATCH[1]}"; rc2=$?
      [ "$rc2" = 0 ] && rc=0
    fi
  fi
  if [ "$rc" = 1 ]; then RV_LOG=unreadable; return 0; fi
  [ "$rc" = 0 ] || return 0
  d="$RV_DETAIL"
  now=$(rv__now); maxd=$(rv__int REVERT_REASON_MAX_AGE_D 30)
  at=$(jq -r '.at | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch empty' <<<"$d" 2>/dev/null)
  [[ "$at" =~ ^[0-9]+$ ]] || { RV_LOG=unreadable; return 0; }
  if [ $((now - at)) -gt $((maxd * 86400)) ]; then RV_LOG="old ($(( (now - at) / 86400 )) d)"; return 0; fi
  case "$(rv__status_of "$d")" in
    unreadable) RV_LOG="none (unreadable row)"; return 0 ;;
    no-signal) RV_LOG="none (no signal)"; return 0 ;;
  esac
  n=$(jq '[.reverts[] | select(.status == "saved" and (.signals | length) > 0)] | length' <<<"$d")
  [ "$n" -gt 0 ] || { RV_LOG="none (no signal left after the size cut)"; return 0; }
  cls=$(jq -r '[.reverts[] | select(.status == "saved" and (.signals | length) > 0) | .signals[].class] | unique | join(",")' <<<"$d")
  while IFS=$'\t' read -r hex body; do
    [ -n "$hex" ] || continue
    line="$line === UNTRUSTED INPUT revert-$hex === ${body:0:1200} === END UNTRUSTED INPUT revert-$hex ==="
  done < <(jq -r '.reverts[] | select(.status == "saved" and (.signals | length) > 0)
      | [(.revert_sha[0:8]), ("revert \(.revert_sha[0:8]) of PR #\(.merged_pr) at \(.at): "
         + ([.signals[] | "[\(.class)] \(.source) \(.url): \(.text)"] | join(" | ")) | gsub("[\t\n]"; " "))] | @tsv' <<<"$d")
  RV_LINE=" THIS TICKET'S LAST MERGE WAS REVERTED ($n time(s)). The rebuild must not fail the same way. Plan a check that would have caught each signal below before merge, and name it in plan.md. Signals:$line"
  RV_LOG="saved $n revert(s) $cls"
  printf '%s' "$RV_LINE"
}

# rv_week_line <days> — one summary line from the project indexes: reverts in
# the last <days> days per project, by their first signal class
# (build > probe > stated; none = read, no signal; unreadable said apart).
rv_week_line() {
  local days="${1:-7}" r base now out
  rv__env
  r=$(rv__root) || { printf 'reverts %sd: mirror unreadable' "$days"; return 0; }
  base="$r/state/revert-reasons"
  [ -e "$base" ] || { printf 'reverts %sd: no data (no capture has run)' "$days"; return 0; }
  [ -d "$base" ] && [ -r "$base" ] && [ -x "$base" ] || { printf 'reverts %sd: mirror unreadable' "$days"; return 0; }
  now=$(rv__now)
  out=$(for f in "$base"/*/index.tsv; do
      [ -e "$f" ] || continue
      if [ -f "$f" ] && [ -r "$f" ]; then
        awk -F'\t' -v p="$(basename "$(dirname "$f")")" '{print p "\t" $0}' "$f" 2>/dev/null || echo "UNREADABLE"
      else
        echo "UNREADABLE"
      fi
    done | jq -nRr --argjson since "$((now - days * 86400))" --arg days "$days" '
      [inputs] as $l
      | if any($l[]; . == "UNREADABLE") then "reverts \($days)d: mirror unreadable" else
        [ $l[] | split("\t") | select(length >= 7)
          | {p:.[0], at:(.[2] | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null), st:.[3], cls:(.[6] | split(","))}
          | select(.at != null and .at >= $since)
          | .c = (if .st == "unreadable" then "unreadable" elif (.cls | index("build")) then "build"
                  elif (.cls | index("probe")) then "probe" elif (.cls | index("stated")) then "stated" else "none" end) ]
        | if length == 0 then "reverts \($days)d: none" else
            "reverts \($days)d: " + (group_by(.p) | sort_by(-length, .[0].p) | map(
              . as $g | ($g | map(.c)) as $c
              | "\($g[0].p) \($g | length) (build \($c | map(select(. == "build")) | length), probe \($c | map(select(. == "probe")) | length), stated \($c | map(select(. == "stated")) | length), none \($c | map(select(. == "none")) | length)"
                + (($c | map(select(. == "unreadable")) | length) as $u | if $u > 0 then ", unreadable \($u)" else "" end) + ")")
              | join(", "))
          end
        end' 2>/dev/null)
  [ -n "$out" ] || out="reverts ${days}d: mirror unreadable"
  printf '%s' "$out"
}
