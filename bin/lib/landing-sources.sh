#!/bin/bash
# bin/lib/landing-sources.sh — the one fetcher behind the digest's `landing`
# block (bin/dora-digest.sh) and bin/landing-replay.sh (BH-6748, wave 5 of
# #6541). Sourced, never executed.
#
# gh-rest: no-graphql
#
# ls_fetch <outdir> <since-iso> <repos-file>
#   <repos-file> is `<project>\t<owner/repo>` lines (the digest's repos.tsv).
#   Writes into <outdir>, one row per line, only rows at or after <since-iso>:
#     decisions.jsonl   GET /api/landing-decisions?repo=<r>&limit=200, paged
#                       newest first by before_id = the smallest id of the last
#                       page (worker/jobs/src/routes/landing-decisions.js)
#     merges.jsonl      GET /api/ledger?kind=merge&limit=1000, one fleet
#                       stream paged by before + before_key; status=merged
#                       rows only (mc_settle_merged writes the detail
#                       `merge-conductor path=direct` for a direct landing)
#     ci-batches.jsonl  GET /api/ci-batches?repo=<r>&since=<since>&limit=5000
#     pulls.jsonl       gh_rest GET repos/<r>/pulls?state=closed&sort=updated
#                       &direction=desc&per_page=100&page=<n>, GH_REST_OPTIONAL=1
#                       (number, title, created_at, merged_at, updated_at,
#                       head_ref, body, labels, repo)
#     ejected.txt       the `ejected <owner/repo>#<n> <head>` lines of
#                       $LANDING_ATTEMPTS, else <harness root>/state/merge-conductor/
#                       attempts.txt (root: $HARNESS, else $H; neither = absent)
#     sources.json      {<source>: {status: ok|error|partial|absent|off, why,
#                       pages, capped}, knobs: {...}}
#   ci-batches and pulls are read only for the repos with landing activity in
#   the window (a decision row, or a direct merge). No activity anywhere: both
#   are `off`, "no landing activity", and GitHub is not called. When every
#   decisions read fails, nothing else is read: the block is n/a anyway.
#   Needs _jobs_req (bin/jobs-client.sh); gh_rest (bin/lib/gh-rest.sh) is
#   optional, and without it pulls is `error`. Writes nothing outside <outdir>.
#   rc 0 always: a failed read is a source status, never an exit.
#
# Knobs, through ph_knob (bin/lib/pr-health.sh): the settings row, then env,
# then the fallback. The seeds are in
# worker/jobs/schema.d/202610261457-bh-6748-landing-report-knobs.sql.
#   landing.report.decision_pages  LANDING_REPORT_DECISION_PAGES  10 (per repo)
#   landing.report.ledger_pages    LANDING_REPORT_LEDGER_PAGES     5 (fleet)
#   landing.report.gh_pages        LANDING_REPORT_GH_PAGES         3 (per repo)

_LS_DIR="$(dirname "${BASH_SOURCE[0]}")"

# _ls_knob <row> <env> <fallback> — a positive integer, never 0.
_ls_knob() {
  local v=""
  command -v ph_knob >/dev/null 2>&1 || . "$_LS_DIR/pr-health.sh" 2>/dev/null
  if command -v ph_knob >/dev/null 2>&1; then v=$(ph_knob "$1" "$2" "$3" 2>/dev/null); fi
  case "$v" in ''|*[!0-9]*|0) v="$3" ;; esac
  printf '%s\n' "$v"
}

# _ls_arr <word>... — a JSON array of strings.
_ls_arr() { if [ "$#" -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -R . | jq -sc .; fi; }

# _ls_src <name> <status> <why> <pages> <capped> — one source's record.
_ls_src() {
  jq -nc --arg n "$1" --arg s "$2" --arg w "$3" --argjson p "${4:-0}" --argjson c "${5:-false}" \
    '{($n): {status: $s, why: (if $w == "" then null else $w end), pages: $p, capped: $c}}' >> "$LS_OUT/.sources"
}

ls_fetch() {
  local out="$1" since="$2" rf="$3" r p page before tmp min n old trunc st why capped pages rows
  local dp lp gp repos=() failed=() active=() dwhy="" dcapped=false dpages=0 dst nwhy=0
  LS_OUT="$out"
  mkdir -p "$out" || return 0
  : > "$out/decisions.jsonl"; : > "$out/merges.jsonl"; : > "$out/ci-batches.jsonl"
  : > "$out/pulls.jsonl"; : > "$out/ejected.txt"; : > "$out/.sources"
  tmp="$out/.body"
  dp=$(_ls_knob landing.report.decision_pages LANDING_REPORT_DECISION_PAGES 10)  # fallback 10: settings row landing.report.decision_pages
  lp=$(_ls_knob landing.report.ledger_pages LANDING_REPORT_LEDGER_PAGES 5)       # fallback 5: settings row landing.report.ledger_pages
  gp=$(_ls_knob landing.report.gh_pages LANDING_REPORT_GH_PAGES 3)               # fallback 3: settings row landing.report.gh_pages
  while IFS=$'\t' read -r p r; do
    [ -n "$r" ] && [ "$r" != "-" ] && repos+=("$r")
  done < "$rf"

  # ── decisions, per repo ──
  if ! command -v _jobs_req >/dev/null 2>&1; then
    dst=error; dwhy="no worker client (bin/jobs-client.sh)"; failed=("${repos[@]}")
  else
    for r in "${repos[@]}"; do
      page=0; before=""; st=ok; why=""; capped=false
      while :; do
        page=$((page + 1))
        p="/api/landing-decisions?repo=$r&limit=200${before:+&before_id=$before}"
        if ! _jobs_req GET "$p" > "$tmp" 2>/dev/null || ! jq -e '.rows | type == "array"' "$tmp" >/dev/null 2>&1; then
          st=error; why="$r: GET $p failed, http=${JOBS_HTTP:-none}"; break
        fi
        min=$(jq -r '[.rows[].id | numbers] | min // empty' "$tmp")
        # An older worker ignores before_id and answers the same page again.
        if [ -n "$before" ] && [ -n "$min" ] && [ "$min" -ge "$before" ]; then
          capped=true; why="$r: cursor ignored"; break
        fi
        jq -c --arg s "$since" '.rows[] | select((.at // "") >= $s)' "$tmp" >> "$out/decisions.jsonl"
        old=$(jq --arg s "$since" '[.rows[] | select((.at // "") < $s)] | length' "$tmp")
        trunc=$(jq -r '.truncated' "$tmp")
        [ "$old" -gt 0 ] || [ "$trunc" != true ] || [ -z "$min" ] && break
        [ "$page" -ge "$dp" ] && { capped=true; why="$r: $dp page cap"; break; }
        before="$min"
      done
      dpages=$((dpages + page))
      [ "$capped" = true ] && dcapped=true
      [ "$st" = error ] && failed+=("$r")
      # The first two reasons, then a count: one line in the digest, not one per repo.
      if [ -n "$why" ]; then
        nwhy=$((nwhy + 1))
        [ "$nwhy" -le 2 ] && dwhy="${dwhy:+$dwhy; }$why"
      fi
    done
    [ "$nwhy" -gt 2 ] && dwhy="$dwhy; +$((nwhy - 2)) more"
    if [ "${#repos[@]}" -eq 0 ]; then dst=error; dwhy="no repos"
    elif [ "${#failed[@]}" -eq 0 ]; then dst=ok
    elif [ "${#failed[@]}" -eq "${#repos[@]}" ]; then dst=error
    else dst=partial; fi
  fi
  jq -nc --arg s "$dst" --arg w "$dwhy" --argjson p "$dpages" --argjson c "$dcapped" \
    --argjson rs "$(_ls_arr "${repos[@]}")" --argjson fs "$(_ls_arr "${failed[@]}")" \
    '{decisions: {status: $s, why: (if $w == "" then null else $w end), pages: $p, capped: $c,
                  repos: $rs, failed: $fs}}' >> "$out/.sources"

  # ── ejected (a local file, read whatever the worker said) ──
  local att="${LANDING_ATTEMPTS:-}" root="${HARNESS:-${H:-}}"
  [ -z "$att" ] && [ -n "$root" ] && att="$root/state/merge-conductor/attempts.txt"
  if [ -z "$att" ]; then
    _ls_src ejected absent "no harness root (HARNESS unset)" 0 false
  elif [ -r "$att" ]; then
    grep -E '^ejected [^ #]+#[0-9]+ [0-9a-fA-F]+' "$att" > "$out/ejected.txt" 2>/dev/null
    _ls_src ejected ok "" 0 false
  else
    _ls_src ejected absent "$att not readable on this box" 0 false
  fi

  if [ "$dst" = error ]; then
    for n in merges ci_batches pulls; do _ls_src "$n" off "every decisions read failed" 0 false; done
    _ls_finish "$out" "$dp" "$lp" "$gp"; return 0
  fi

  # ── merges, one fleet stream ──
  page=0; before=""; local bkey="" last; st=ok; why=""; capped=false
  while :; do
    page=$((page + 1))
    p="/api/ledger?kind=merge&limit=1000"
    [ -n "$before" ] && p="$p&before=$(jq -rn --arg v "$before" '$v|@uri')&before_key=$(jq -rn --arg v "$bkey" '$v|@uri')"
    if ! _jobs_req GET "$p" > "$tmp" 2>/dev/null || ! jq -e '.ledgers | type == "array"' "$tmp" >/dev/null 2>&1; then
      st=error; why="GET $p failed, http=${JOBS_HTTP:-none}"; break
    fi
    jq -c --arg s "$since" '.ledgers[] | select(.status == "merged" and (.updated_at // "") >= $s)
      | {key, status, detail, updated_at}' "$tmp" >> "$out/merges.jsonl"
    rows=$(jq '.ledgers | length' "$tmp")
    old=$(jq --arg s "$since" '[.ledgers[] | select((.updated_at // "") < $s)] | length' "$tmp")
    [ "$old" -gt 0 ] || [ "$rows" -lt 1000 ] && break
    [ "$page" -ge "$lp" ] && { capped=true; why="$lp page cap"; break; }
    last=$(jq -c '.ledgers[-1]' "$tmp")
    before=$(jq -r '.updated_at // ""' <<<"$last"); bkey=$(jq -r '.key // ""' <<<"$last")
  done
  _ls_src merges "$st" "$why" "$page" "$capped"

  # ── activity: repos with a decision row or a direct merge in the window ──
  mapfile -t active < <( { jq -r '.repo // empty' "$out/decisions.jsonl"
    jq -r 'select((.detail // "") | split(" ") | index("path=direct")) | .key // ""' "$out/merges.jsonl" \
      | sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#p'; } | sort -u)
  if [ "${#active[@]}" -eq 0 ]; then
    _ls_src ci_batches off "no landing activity" 0 false
    _ls_src pulls off "no landing activity" 0 false
    _ls_finish "$out" "$dp" "$lp" "$gp"; return 0
  fi

  # ── CI batches, per active repo ──
  st=ok; why=""; capped=false; pages=0
  for r in "${active[@]}"; do
    pages=$((pages + 1))
    p="/api/ci-batches?repo=$r&since=$since&limit=5000"
    if ! _jobs_req GET "$p" > "$tmp" 2>/dev/null || ! jq -e '.rows | type == "array"' "$tmp" >/dev/null 2>&1; then
      st=error; why="${why:+$why; }$r: GET $p failed, http=${JOBS_HTTP:-none}"; continue
    fi
    jq -c --arg r "$r" '.rows[] | . + {repo: (.repo // $r)}' "$tmp" >> "$out/ci-batches.jsonl"
    [ "$(jq -r '.truncated' "$tmp")" = true ] && capped=true
  done
  _ls_src ci_batches "$st" "$why" "$pages" "$capped"

  # ── pulls (GitHub REST), per active repo ──
  st=ok; why=""; capped=false; pages=0
  if ! command -v gh_rest >/dev/null 2>&1; then
    st=error; why="gh_rest is not loaded (bin/lib/gh-rest.sh)"
  else
    for r in "${active[@]}"; do
      command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$r" >/dev/null 2>&1
      page=0
      while :; do
        page=$((page + 1)); pages=$((pages + 1))
        p="repos/$r/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$page"
        GH_REST_OPTIONAL=1 gh_rest GET "$p" > "$tmp" 2>/dev/null; n=$?
        if [ "$n" != 0 ] || ! jq -e 'type == "array"' "$tmp" >/dev/null 2>&1; then
          st=error; why="${why:+$why; }$r: GET $p rc $n (${GH_REST_REASON:-status ${GH_REST_STATUS:-000}})"; break
        fi
        jq -c --arg r "$r" --arg s "$since" '.[] | select((.updated_at // "") >= $s)
          | {repo: $r, number, title, created_at, merged_at, updated_at, head_ref: (.head.ref // null),
             body: ((.body // "")[0:2000]), labels: [(.labels // [])[] | .name]}' "$tmp" >> "$out/pulls.jsonl"
        rows=$(jq 'length' "$tmp")
        old=$(jq --arg s "$since" '[.[] | select((.updated_at // "") < $s)] | length' "$tmp")
        [ "$old" -gt 0 ] || [ "$rows" -lt 100 ] && break
        [ "$page" -ge "$gp" ] && { capped=true; why="${why:+$why; }$r: $gp page cap"; break; }
      done
    done
  fi
  _ls_src pulls "$st" "$why" "$pages" "$capped"
  _ls_finish "$out" "$dp" "$lp" "$gp"
  return 0
}

# _ls_finish <out> <dp> <lp> <gp> — sources.json from the per-source records.
_ls_finish() {
  jq -s --argjson dp "$2" --argjson lp "$3" --argjson gp "$4" \
    'add + {knobs: {decision_pages: $dp, ledger_pages: $lp, gh_pages: $gp}}' "$1/.sources" > "$1/sources.json"
  rm -f "$1/.sources" "$1/.body"
}
