# shellcheck shell=bash
# bin/lib/mrb-act.sh — main-red-bisect: act on a bisected episode. Sourced,
# never run.
#
# BH-3685 contract (BH-3693): siblings replace the bodies, never the
# signatures. The file defines functions only: no shell options, no exit, no
# output when sourced.
#
# THE RC CONTRACT. 0 means the episode was fully acted on. Any non-zero rc
# means the driver MUST NOT record a terminal episode row, so a driver never
# burns an episode it did not act on. BH-3697 fills the bodies in and uses:
#   1   failed or refused (bad episode, no root, a GitHub write that did not
#       answer 201); the next tick retries, and the ledger rows below make
#       that retry safe
#   75  the ledger or a dependency is unreachable; nothing was done
#
# THE CALLER PROVIDES job_ledger_row / job_ledger_put /
# metric_flake_quarantine_put (bin/jobs-client.sh), gh_default_auth_for_slug
# (bin/lib/gh-app-auth.sh) and, for mrb_act_culprit, MRB_REPO_DIR: a checkout
# of <slug> with an `origin` remote. The root is ${HARNESS:-${H:-}}; with none
# both functions return 1.
#
# THE LEDGER (kind / key / status):
#   main_red_revert  <slug>@<culprit>  opening | done | conflict |
#                                      already-reverted | disabled
#   main_red_reland  <slug>@<culprit>  filed
#   main_red_fix     <slug>@<sha1 of the sorted suites, 12>  filed
#   main_red_mapgap  <slug>@<culprit>  filed
#   main_red_attrib  <slug>@<culprit>  gap | no-gap | serial | unknown
#                    (BH-4981: the queue lane and risk tier the culprit got,
#                    written LAST, after any map-gap ticket; Mission Control's
#                    /ci counts these rows)
# `opening` is written BEFORE the push and `done` only after the pulls 201, so
# a revert branch is never untracked: an `opening` row is adopted through
# GET pulls?head= on the next call, never POSTed twice. Every ticket also
# carries a body marker, which heals a row lost after its 201.
#
# KNOBS: MAIN_RED_BISECT_REVERT (1; 0 = ticket only), MAIN_RED_BISECT_QUARANTINE_MAX
# (3; 0 = never quarantine), MAIN_RED_BISECT_PROTECTED_RE.
#
# gh-rest: no-graphql
[ "$(type -t gh_rest)" = function ] || . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" 2>/dev/null
[ "$(type -t gh_rest_issue_list)" = function ] || . "$(dirname "${BASH_SOURCE[0]}")/gh-rest-list.sh" 2>/dev/null
[ "$(type -t main_red_label_resolve)" = function ] || . "$(dirname "${BASH_SOURCE[0]}")/main-red-label.sh" 2>/dev/null
[ "$(type -t pr_trailers_apply)" = function ] || . "$(dirname "${BASH_SOURCE[0]}")/pr-trailers.sh" 2>/dev/null
[ "$(type -t hotfix_label)" = function ] || . "$(dirname "${BASH_SOURCE[0]}")/hotfix-lib.sh" 2>/dev/null

# _mrb_kv <episode> <key> — the value; the LAST line wins.
_mrb_kv() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }

# _mrb_have <fn>... — rc 0 when every one is defined.
_mrb_have() { local f; for f in "$@"; do [ "$(type -t "$f")" = function ] || return 1; done; }

# _mrb_alert <severity> <id> <text> — reads the caller's $h. Never fails.
_mrb_alert() { "$h/bin/lane-alert.sh" --severity "$1" --id "$2" main-red-bisect "$3" >/dev/null 2>&1 || true; }

# _mrb_wt_rm <dir> — removes a dir this file made, then prunes the worktree.
_mrb_wt_rm() {
  case "$1" in "${TMPDIR:-/tmp}"/mrb-act.*) rm -rf -- "$1" ;; esac
  [ -n "${MRB_REPO_DIR:-}" ] && git -C "$MRB_REPO_DIR" worktree prune >/dev/null 2>&1
  return 0
}

# _mrb_protected <suite> — rc 0 when the suite must never be quarantined: it
#   is listed in catalog/test-impact-always.txt, matches the protected regex,
#   or the catalog cannot be read (fail closed). Reads the caller's $h.
_mrb_protected() {
  local re="${MAIN_RED_BISECT_PROTECTED_RE:-(ratchet|switch-|merge-|approval|spend|brake|scratch|trace-safety)}"
  local f="$h/catalog/test-impact-always.txt"
  [ -r "$f" ] || return 0
  awk -v s="$1" '!/^[[:space:]]*#/ && $1 == s {f=1} END {exit !f}' "$f" && return 0
  [[ $1 =~ $re ]]
}

# _mrb_file_ticket <repo> <kind> <key> <marker> <title> <body-file>
#   One ai-build issue, in the bin/lib/lookback-file.sh order: the ledger row
#   (filed -> done; unreadable -> 75), the marker in an open issue (a hit
#   writes the row), then the create (only a 201 with a number counts).
#   Sets MRB_TICKET_URL in the calling shell. rc 0 | 1 | 75.
_mrb_file_ticket() {
  local row rc=0 t
  MRB_TICKET_URL=""
  row=$(job_ledger_row "$2" "$3") || rc=$?
  case "$rc" in
    0) if [ "$(jq -r '.status // ""' <<<"$row" 2>/dev/null)" = filed ]; then
         MRB_TICKET_URL=$(jq -r '.detail | (fromjson? // {}) | .url? // ""' <<<"$row" 2>/dev/null)
         return 0
       fi ;;
    2) ;;
    *) return 75 ;;
  esac
  t=$(mktemp -d "${TMPDIR:-/tmp}/mrb-act.XXXXXX") || return 1
  rc=0; _mrb_file_new "$t" "$@" || rc=$?
  _mrb_wt_rm "$t"
  return "$rc"
}

_mrb_file_new() { # <tmp> <repo> <kind> <key> <marker> <title> <body-file>
  local t="$1" repo="$2" rc=0 len n url
  gh_rest_issue_list "$repo" open "" 1000 > "$t/list" || rc=$?
  len=$(jq 'length' "$t/list" 2>/dev/null) || len=""
  [ "$rc" = 0 ] && [[ "$len" =~ ^[0-9]+$ ]] && [ "$len" -lt 1000 ] || return 1
  n=$(jq -r --arg m "$5" '[.[] | select((.body // "") | contains($m))] | sort_by(.number) | .[0].number // empty' "$t/list")
  if [ -n "$n" ]; then
    url=$(jq -r --argjson n "$n" '[.[] | select(.number == $n)][0].html_url // ""' "$t/list")
  else
    { cat "$7"; printf '\n%s\n' "$5"; } > "$t/body"
    jq -n --arg t "$6" --rawfile b "$t/body" '{title: $t, body: $b, labels: ["ai-build"]}' > "$t/payload"
    rc=0; gh_rest POST "repos/$repo/issues" --input "$t/payload" > "$t/out" || rc=$?
    n=$(jq -e '.number | numbers' "$t/out" 2>/dev/null) || n=""
    [ "$rc" = 0 ] && [ "$GH_REST_STATUS" = 201 ] && [ -n "$n" ] || return 1
    url=$(jq -r '.html_url // ""' "$t/out")
  fi
  # A lost row is healed by the marker on the next call, so this write is not fatal.
  job_ledger_put "$3" "$4" filed "$(jq -nc --argjson n "$n" --arg u "$url" '{issue: $n, url: $u}')" || true
  MRB_TICKET_URL=$url
  return 0
}

# mrb_act_culprit <episode-file>
#   Acts on an episode whose bisect found a culprit merge (culprit=, pr=):
#   reverts it through a PR on main-red-revert/pr-<N>-<culprit12> and files a
#   re-land ticket. Guards, in order: the main_red_revert row (done /
#   conflict / disabled re-file the ticket only, already-reverted is done,
#   opening adopts the open PR), a culprit that is itself a revert (critical,
#   rc 0), git's revert of #N already on origin/main (already-reverted), the
#   knob (ticket only). A revert that does not apply is aborted: critical
#   alert, ledger conflict, ticket, no PR. Then, unless the culprit is itself
#   a revert, the map-gap step (_mrb_mapgap).
#   stdout: nothing. rc: see THE RC CONTRACT.
mrb_act_culprit() {
  local h="${HARNESS:-${H:-}}" d rc=0
  [ -n "$h" ] && [ -r "${1:-}" ] || return 1
  _mrb_have job_ledger_row job_ledger_put gh_rest gh_rest_issue_list gh_default_auth_for_slug \
    main_red_label_resolve || return 75
  d=$(mktemp -d "${TMPDIR:-/tmp}/mrb-act.XXXXXX") || return 1
  _mrb_culprit "$d" "$1" || rc=$?
  [ "$rc" = 0 ] && { _mrb_mapgap "$d" "$1" || rc=$?; }
  _mrb_wt_rm "$d"
  return "$rc"
}

_mrb_culprit() { # <tmp> <episode>
  local d="$1" ep="$2" k slug red green run suites culprit pr pr_title pr_branch bisect shortcut
  local m12 br lkey row="" rrc=0 st="" first runurl prn url sha files
  for k in slug red green run suites culprit pr pr_title pr_branch bisect shortcut; do printf -v "$k" '%s' "$(_mrb_kv "$ep" "$k")"; done
  [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$culprit" =~ ^[0-9a-f]{40}$ ]] && [[ "$pr" =~ ^[0-9]+$ ]] || return 1
  m12=${culprit:0:12}; br="main-red-revert/pr-$pr-$m12"; lkey="$slug@$culprit"; first=${suites%% *}
  runurl="https://github.com/$slug/actions/runs/$run"

  # 1. the ledger row, first; an outage is never "no row"
  row=$(job_ledger_row main_red_revert "$lkey") || rrc=$?
  case "$rrc" in 0) st=$(jq -r '.status // ""' <<<"$row" 2>/dev/null) ;; 2) ;; *) return 75 ;; esac
  case "$st" in
    done) _mrb_reland "" "$(jq -r '.detail | (fromjson? // {}) | .url? // ""' <<<"$row" 2>/dev/null)"; return ;;
    conflict) _mrb_reland "Not reverted: revert did not apply cleanly; needs a hand revert." ""; return ;;
    disabled) _mrb_reland "Not reverted: revert disabled by knob; revert #$pr by hand." ""; return ;;
    already-reverted) return 0 ;;
    opening)
      rrc=0; gh_rest GET "repos/$slug/pulls?head=${slug%%/*}:$br&state=all" > "$d/pulls" || rrc=$?
      [ "$rrc" = 0 ] && jq -e 'type == "array"' "$d/pulls" >/dev/null 2>&1 || return 75
      prn=$(jq -r '.[0].number // empty' "$d/pulls")
      if [ -n "$prn" ]; then
        _mrb_finish "$prn" "$(jq -r '.[0].html_url // ""' "$d/pulls")" "$(jq -r '.[0].head.sha // ""' "$d/pulls")"
        return
      fi
      # No PR. `opening` is written BEFORE the push, so a failed token mint,
      # push or pulls POST leaves it with nothing (or only a branch) behind.
      # Ask the remote which: a pushed branch gets its PR opened (GitHub
      # answers 422 to a second open PR for the same head, so this cannot
      # duplicate one); no branch means the revert was never pushed, so it is
      # cut again below. Only a branch whose PR open is refused AGAIN pages.
      _mrb_repo_ok || return 75
      gh_default_auth_for_slug "$slug" >/dev/null 2>&1 || return 75
      rrc=0; sha=$(git -C "$MRB_REPO_DIR" ls-remote --exit-code origin "refs/heads/$br" 2>/dev/null) || rrc=$?
      case "$rrc" in
        0) sha=${sha%%[[:space:]]*}
           [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 75
           _mrb_open_pr "$sha" && return
           _mrb_alert critical "main-red-revert-orphan:$slug:$m12" \
             "revert branch $br is pushed but opening its PR was refused again (HTTP ${GH_REST_STATUS:-?}); open it or delete the branch by hand"
           return 1 ;;
        2) ;;
        *) return 75 ;;
      esac ;;
  esac

  # 2. never revert a revert
  case "$pr_branch" in main-red-revert/*)
    _mrb_alert critical "main-red-revert-loop:$slug:$m12" \
      "culprit #$pr is itself a main-red revert; not reverting a revert, fix main by hand"
    return 0 ;;
  esac

  # 3. already reverted on main (the trailing space keeps #10 from matching #102)
  _mrb_repo_ok || return 75
  git -C "$MRB_REPO_DIR" fetch -q origin main >/dev/null 2>&1 || return 75
  git -C "$MRB_REPO_DIR" log --format=%s "$culprit..origin/main" > "$d/log" 2>/dev/null || return 1
  if grep -qF "Revert \"Merge pull request #$pr " "$d/log"; then
    job_ledger_put main_red_revert "$lkey" already-reverted || return 1
    return 0
  fi

  # 4. the knob
  if [ "${MAIN_RED_BISECT_REVERT:-1}" = 0 ]; then
    job_ledger_put main_red_revert "$lkey" disabled || return 1
    _mrb_reland "Not reverted: revert disabled by knob; revert #$pr by hand." ""
    return
  fi

  # 5. the revert, keeping git's default subject (bin/lead-review-precision.sh counts it)
  git -C "$MRB_REPO_DIR" worktree add -q -f --detach "$d/wt" origin/main >/dev/null 2>&1 || return 1
  if ! git -C "$d/wt" revert -m 1 --no-edit "$culprit" >/dev/null 2>&1; then
    files=$(git -C "$d/wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
    git -C "$d/wt" revert --abort >/dev/null 2>&1
    rrc=0; job_ledger_put main_red_revert "$lkey" conflict || rrc=1
    _mrb_alert critical "main-red-revert-conflict:$slug:$m12" \
      "the revert of #$pr ($pr_title) did not apply cleanly on main: ${files:-no file named}; revert it by hand"
    _mrb_reland "Not reverted: revert did not apply cleanly; needs a hand revert. Conflicting files: ${files:-none named}" "" || return
    return "$rrc"
  fi
  job_ledger_put main_red_revert "$lkey" opening || return 75
  gh_default_auth_for_slug "$slug" >/dev/null 2>&1 || return 1
  git -C "$d/wt" push -q origin "HEAD:refs/heads/$br" >/dev/null 2>&1 || return 1
  _mrb_open_pr "$(git -C "$d/wt" rev-parse HEAD)"
}

# _mrb_open_pr <pushed-sha> — open the revert PR for $br and finish. rc 1 when
# the POST is refused; the `opening` row stays, so the next tick retries it.
_mrb_open_pr() {
  local sha="$1" rrc=0 prn tk=none
  { printf 'harness build: main-red-bisect revert of #%s\n\n' "$pr"
    if [ "${shortcut:-}" = one-merge ]; then
      printf 'Main went red in %s. Merge %s (#%s) is the only merge since the last green %s, so this reverts it without a bisect.\n' \
        "$runurl" "$culprit" "$pr" "$green"
    else
      printf 'Main went red in %s. The bisect pinned it on merge %s (#%s), so this reverts it.\n' "$runurl" "$culprit" "$pr"
    fi
    printf 'A re-land ticket carries the fix.\n\nRed suites: %s\nLast green: %s\nFirst red: %s\n' "$suites" "$green" "$red"
    _mrb_table
  } > "$d/prbody"
  # >>> pr trailers (BH-3987)
  # The lane opened it, for the culprit's ticket when its title starts `KEY:`.
  # A failed write is one stderr line and the revert opens untrailered.
  [[ "$pr_title" =~ ^([A-Z][A-Z0-9]*-[0-9]+): ]] && tk=${BASH_REMATCH[1]}
  if [ "$(type -t pr_trailers_apply)" = function ]; then
    pr_trailers_apply "$d/prbody" lane:main-red-bisect "$tk" \
      || echo "mrb-act: pr trailers: could not write $d/prbody — PR opened without trailers" >&2
  fi
  jq -n --arg t "revert: #$pr — $pr_title" --arg h "$br" --rawfile b "$d/prbody" \
    '{title: $t, head: $h, base: "main", body: $b}' > "$d/pr.json"
  rrc=0; gh_rest POST "repos/$slug/pulls" --input "$d/pr.json" > "$d/pr.out" || rrc=$?
  # <<< pr trailers
  prn=$(jq -e '.number | numbers' "$d/pr.out" 2>/dev/null) || prn=""
  [ "$rrc" = 0 ] && [ "$GH_REST_STATUS" = 201 ] && [ -n "$prn" ] || return 1
  _mrb_finish "$prn" "$(jq -r '.html_url // ""' "$d/pr.out")" "$sha"
}

# _mrb_repo_ok — MRB_REPO_DIR is a git checkout. When it is not, page once per
# slug (the driver did not export it) instead of failing every tick in silence.
_mrb_repo_ok() {
  [ -n "${MRB_REPO_DIR:-}" ] && git -C "$MRB_REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 && return 0
  _mrb_alert critical "main-red-revert-norepo:$slug" \
    "MRB_REPO_DIR (${MRB_REPO_DIR:-unset}) is not a git checkout, so the revert of #$pr cannot be cut; export it in the driver"
  return 1
}

# _mrb_table — the bisect table, fenced, when bisect= names a readable file.
_mrb_table() {
  [ -n "$bisect" ] && [ -r "$bisect" ] || return 0
  printf '\nBisect:\n\n```\n'; head -60 "$bisect"; printf '```\n'
}

# _mrb_finish <pr> <url> <head-sha> — label, review request, ledger done,
#   re-land ticket, digest. Reads _mrb_culprit's locals. The label and the
#   review request are best-effort and named in the digest when they fail.
# The labels are main-red's (Mergify's hotfix queue) and hotfix_label's (the
# merge conductor's hotfix-first order); `hotfix` is that function's own default.
_mrb_finish() {
  local n="" rc=0 hl=hotfix one=""
  [ "${shortcut:-}" = one-merge ] && one=" (the only merge since the last green; no bisect)"
  [ "$(type -t hotfix_label)" = function ] && hl=$(hotfix_label "$h")
  jq -n --arg l "$(main_red_label_resolve "$h")" --arg x "$hl" \
    '{labels: (if $x == "" or $x == $l then [$l] else [$l, $x] end)}' > "$d/label.json"
  gh_rest POST "repos/$slug/issues/$1/labels" --input "$d/label.json" >/dev/null 2>&1 || n="$n; label failed"
  "$h/bin/lead-verdict.sh" request "$slug" "$1" "$3" >/dev/null 2>&1 || n="$n; review request failed"
  job_ledger_put main_red_revert "$lkey" done \
    "$(jq -nc --argjson p "$1" --arg u "$2" --arg r "$red" --arg s "$suites" '{pr: $p, url: $u, red: $r, suites: $s}')" || return 1
  _mrb_reland "" "$2" || rc=$?
  _mrb_alert warn "main-red-revert:$slug:$m12" \
    "reverted #$pr ($pr_title): broke $suites; revert PR $2, re-land ticket ${MRB_TICKET_URL:-not filed}$n$one"
  return "$rc"
}

# _mrb_reland <flag-line> <revert-pr-url> — the re-land ticket. Reads _mrb_culprit's locals.
_mrb_reland() {
  local s sl=()
  read -ra sl <<<"$suites"
  { [ -z "$1" ] || printf '%s\n\n' "$1"
    if [ "${shortcut:-}" = one-merge ]; then
      printf 'Merge #%s (%s) broke main. It is the only merge since the last green %s, so no bisect ran.\n\n' \
        "$pr" "$pr_title" "$green"
    else printf 'Merge #%s (%s) broke main. The bisect pinned the red on it.\n\n' "$pr" "$pr_title"; fi
    [ -z "$2" ] || printf 'Revert PR: %s\n' "$2"
    printf 'Original PR: https://github.com/%s/pull/%s\nRed run: %s\n\nRed suites:\n' "$slug" "$pr" "$runurl"
    for s in ${sl[@]+"${sl[@]}"}; do printf -- '- %s: red\n' "$s"; done
    _mrb_table
    if [ -n "$2" ]; then printf '\nRe-apply #%s with the fix for %s; the revert PR above must merge first.\n' "$pr" "$suites"
    else printf '\nRevert #%s by hand first, then re-apply it with the fix for %s.\n' "$pr" "$suites"; fi
  } > "$d/reland"
  _mrb_file_ticket "$slug" main_red_reland "$lkey" "<!-- main-red-reland: $lkey -->" \
    "Re-land #$pr ($pr_title) — reverted: broke $first" "$d/reland"
}

# _mrb_mapgap <tmp> <episode> — BH-4981. Did the impact map let this break
#   through? The lane the merge queue would give the culprit's changed files
#   (qp_impact, bin/lib/queue-partition.sh, over $h's current map) and its
#   risk tier, against the red suites. A red suite outside every scope and not
#   an always-suite is a map gap: one ai-build ticket per culprit. A serial
#   lane ran the full suite, so it is never a gap; an unavailable qp lib is
#   `unknown` with one warn, never `no-gap`. The main_red_attrib row is the
#   step's terminal marker and is written last. rc: see THE RC CONTRACT.
_mrb_mapgap() {
  local d="$1" ep="$2" k slug red run suites culprit pr pr_title pr_branch lkey m12 rc=0
  local qp="" lane reason="" tier=unknown s missed=() st url="" row gap_url="" first
  local -a sl=()
  for k in slug red run suites culprit pr pr_title pr_branch; do printf -v "$k" '%s' "$(_mrb_kv "$ep" "$k")"; done
  case "$pr_branch" in main-red-revert/*) return 0 ;; esac
  [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$culprit" =~ ^[0-9a-f]{40}$ ]] && [[ "$pr" =~ ^[0-9]+$ ]] || return 1
  lkey="$slug@$culprit"; m12=${culprit:0:12}
  job_ledger_row main_red_attrib "$lkey" >/dev/null || rc=$?
  case "$rc" in 0) return 0 ;; 2) ;; *) return 75 ;; esac

  _mrb_repo_ok || return 75
  git -C "$MRB_REPO_DIR" diff --name-only "$culprit^1" "$culprit" > "$d/changed" 2>/dev/null || return 1
  [ "$(type -t qp_impact)" = function ] || . "${BASH_SOURCE[0]%/*}/queue-partition.sh" 2>/dev/null
  if [ "$(type -t qp_impact)" = function ]; then
    QP_TITLE="$pr_title" QP_HEAD_REF="$pr_branch" QP_LABELS="" qp_impact "$d/changed" > "$d/qp" 2>/dev/null
    qp=$(head -1 "$d/qp")
  fi
  case "$qp" in
    lane=scoped) lane=scoped; sed 1d "$d/qp" > "$d/scopes" ;;
    "lane=serial reason="*) lane=serial; reason=${qp#lane=serial reason=} ;;
    *) lane=unknown; reason="queue-partition unavailable" ;;
  esac
  [ -s "$d/scopes" ] || : > "$d/scopes"
  [ "$(type -t risk_tier)" = function ] && tier=$(risk_tier "$d/changed" 2>/dev/null)
  [ -n "$tier" ] || tier=unknown

  read -ra sl <<<"$suites"
  if [ "$lane" = scoped ] && [ ! -r "$h/catalog/test-impact-always.txt" ]; then
    lane=unknown; reason="catalog/test-impact-always.txt unreadable"
  fi
  if [ "$lane" = scoped ]; then
    for s in ${sl[@]+"${sl[@]}"}; do
      grep -qxF -- "$s" "$d/scopes" && continue
      awk -v s="$s" '!/^[[:space:]]*#/ && $1 == s {f=1} END {exit !f}' "$h/catalog/test-impact-always.txt" && continue
      missed+=("$s")
    done
  fi
  case "$lane" in
    serial) st=serial ;;
    unknown) st=unknown
      _mrb_alert warn "main-red-mapgap-unknown:$slug:$m12" \
        "could not tell whether the impact map missed #$pr's break ($reason); no map-gap ticket filed" ;;
    *) if [ "${#missed[@]}" -gt 0 ]; then st=gap; else st=no-gap; fi ;;
  esac

  rc=0; row=$(job_ledger_row main_red_revert "$lkey") || rc=$?
  case "$rc" in 0) url=$(jq -r '.detail | (fromjson? // {}) | .url? // ""' <<<"$row" 2>/dev/null) ;; 2) ;; *) return 75 ;; esac
  if [ "$st" = gap ]; then
    first=${missed[0]}
    { printf 'Main went red on %s and the bisect pinned it on #%s (%s), which the merge queue ran in a scoped lane that never reached the red suite.

' "$slug" "$pr" "$pr_title"
      printf 'Culprit PR: https://github.com/%s/pull/%s
Red run: https://github.com/%s/actions/runs/%s
' "$slug" "$pr" "$slug" "$run"
      [ -z "$url" ] || printf 'Revert PR: %s
' "$url"
      printf '
Files #%s changed:
' "$pr"; sed 's/^/- /' "$d/changed"
      printf '
Lane the queue gave it: scoped (risk tier %s)
Scopes:
' "$tier"; sed 's/^/- /' "$d/scopes"
      printf '
Red suites the scopes missed:
'; printf -- '- %s
' "${missed[@]}"
      printf '
Fix the impact map (bin/test-impact.sh) so these files reach these suites; the selection rule is not the bug.
'
    } > "$d/gap"
    _mrb_file_ticket "$slug" main_red_mapgap "$lkey" "<!-- main-red-mapgap: $lkey -->" \
      "Impact map gap: #$pr reached $first without the map knowing" "$d/gap" || return
    gap_url=$MRB_TICKET_URL
  fi
  job_ledger_put main_red_attrib "$lkey" "$st" "$(jq -nc --argjson p "$pr" --arg t "$pr_title" --arg r "$red" \
    --arg run "$run" --arg l "$lane" --arg why "$reason" --arg tier "$tier" --rawfile sc "$d/scopes" \
    --arg m "${missed[*]+"${missed[*]}"}" --arg ru "$url" --arg gu "$gap_url" \
    '{pr: $p, pr_title: $t, red: $r, run: $run, lane: $l, reason: $why, risk_tier: $tier,
      scopes: ($sc | split("\n") | map(select(length > 0))), missed: ($m | split(" ") | map(select(length > 0))),
      revert_url: $ru, gap_url: $gu}')" || return 1
  return 0
}

# mrb_act_notmerge <episode-file>
#   Acts on an episode the bisect could not pin on a merge: quarantines each
#   red suite (up to MAIN_RED_BISECT_QUARANTINE_MAX, never a protected one,
#   which pages critical instead) and files one fix ticket naming what was
#   quarantined, refused or skipped. rc 0 only when the ticket is filed and
#   every quarantine write it attempted succeeded.
#   stdout: nothing. rc: see THE RC CONTRACT.
mrb_act_notmerge() {
  local h="${HARNESS:-${H:-}}" d rc=0
  [ -n "$h" ] && [ -r "${1:-}" ] || return 1
  _mrb_have job_ledger_row job_ledger_put gh_rest gh_rest_issue_list metric_flake_quarantine_put || return 75
  d=$(mktemp -d "${TMPDIR:-/tmp}/mrb-act.XXXXXX") || return 1
  _mrb_notmerge "$d" "$1" || rc=$?
  _mrb_wt_rm "$d"
  return "$rc"
}

_mrb_notmerge() { # <tmp> <episode>
  local d="$1" ep="$2" k slug red green run suites bisect g12 max hash fkey s rc=0 runurl sum
  local -a all=() q=() rows=()
  for k in slug red green run suites bisect; do printf -v "$k" '%s' "$(_mrb_kv "$ep" "$k")"; done
  read -ra all <<<"$suites"
  [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [ -n "$green" ] && [ "${#all[@]}" -gt 0 ] || return 1
  g12=${green:0:12}; runurl="https://github.com/$slug/actions/runs/$run"
  max=${MAIN_RED_BISECT_QUARANTINE_MAX:-3}; [[ "$max" =~ ^[0-9]+$ ]] || max=3
  hash=$(printf '%s\n' "${all[@]}" | sort | sha1sum | cut -c1-12)
  # The ledger first: an outage writes nothing, not even a quarantine row.
  # The key carries the episode (its last-green sha): the same suite set red
  # again weeks later is a new red and gets a new ticket, not the closed one.
  fkey="$slug@$hash@$g12"
  job_ledger_row main_red_fix "$fkey" >/dev/null || [ $? = 2 ] || return 75

  for s in "${all[@]}"; do
    if _mrb_protected "$s"; then
      rows+=("- $s: protected, not quarantined")
      _mrb_alert critical "main-red-protected:$slug:$s" \
        "$s is red on $slug main with no culprit merge and is protected, so it was not quarantined; fix it by hand"
    else q+=("$s"); fi
  done
  if [ "${#q[@]}" -gt 0 ] && { [ "$max" = 0 ] || [ "${#q[@]}" -gt "$max" ]; }; then
    for s in "${q[@]}"; do rows+=("- $s: not quarantined (${#q[@]} suites, cap $max)"); done
    _mrb_alert critical "main-red-quarantine-cap:$slug:$g12" \
      "${#q[@]} suites red on $slug main with no culprit merge, over the quarantine cap of $max; nothing quarantined, fix by hand: ${q[*]}"
  else
    for s in ${q[@]+"${q[@]}"}; do
      if metric_flake_quarantine_put "$slug" "$s" 1 "not-a-merge red since $g12: $runurl" main-red-bisect; then
        rows+=("- $s: quarantined")
      else rows+=("- $s: quarantine write FAILED"); rc=1; fi
    done
  fi

  { printf 'Main is red on %s and no merge caused it.\n\n' "$slug"
    printf 'P0: %s (last CI-green sha) probed red.\nP1: %s (first red sha) probed red.\nRed run: %s\n\n' "$green" "$red" "$runurl"
    printf 'Quarantine:\n'; printf '%s\n' "${rows[@]}"
    _mrb_table
    printf '\nFix the suites, then lift any quarantine above.\n'
  } > "$d/fix"
  _mrb_file_ticket "$slug" main_red_fix "$fkey" "<!-- main-red-fix: $fkey -->" \
    "Fix ${all[0]} — red on main with no culprit merge (since $g12)" "$d/fix" || return
  sum=$(printf '%s' "${rows[*]}" | sed 's/^- //; s/ - /, /g')
  _mrb_alert warn "main-red-fix:$slug:$hash:$g12" \
    "red on $slug main with no culprit merge: ${all[*]}; $sum; fix ticket ${MRB_TICKET_URL:-unknown}"
  return "$rc"
}
