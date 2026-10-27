#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates-selfcheck.sh — what gates 7 and 8 of the worklist share
# (75-self-check.sh, 78-body-lint.sh): the pre-review self-check of
# bin/lead-review-enqueue.sh (BH-5798, BH-5790, header `self`). Sourced by
# those gate files, never run.
#
#   lgsc_run <slug> <n> <head>   runs psc_check (bin/lib/pr-self-check.sh)
#       ONCE per head per process, and caches its output in
#       $(lgs_dir)/psc-<slug_>-<n>-<h12> (LGSC_OUT is that path). rc 0 = it
#       ran: the file holds its REFUSE/NOTE lines. rc 2 = it cannot run, which
#       holds nothing (the enqueue's rule: "a check that cannot run holds
#       nothing"): PR_SELF_CHECK=0, no psc_check, no catalog, no clone of the
#       repo, no PR body, or a base or head the clone cannot get.
#       The body comes from lgs_pr_body (55-snapshot.sh), else a live gh_rest
#       read. The clone fetches the base and the head only when it lacks one of
#       them. The linked issue (Closes/Fixes/Resolves/Refs/Part of #N) is read
#       once: its body for the body-* rules, its title and labels for the perf
#       trigger, and the repo and number for that trigger's one parent hop. A
#       failed read leaves all of them empty. The title key (`BH-N: ...`) is
#       the PR's own key (BH-6392).
#   lgsc_hold <slug> <n> <head> <refusals>   the enqueue's hold, moved: the
#       marker state/lead-review-enqueue/selfcheck-<slug_>-<n>-<h12> (first
#       line = first-sight epoch), ONE PR comment per (head, body cksum) naming
#       <refusals> (a `commented <cksum>` line, written only after a 2xx), and
#       the bound PR_SELF_CHECK_MAX_WAIT_MIN. rc 11 while the marker is younger
#       than the bound (one `[skip selfcheck]` line); rc 0 past it, with one
#       log line.
#   lgsc_refusals <class>  the cached REFUSE lines, `REFUSE ` cut: class body =
#       the body-* rules, other = the rest, all = every one.
#   lgsc_notes             the cached NOTE body-* lines (the note rules).
#                          and the NOTE callers-not-ported lines (BH-7815).

# shellcheck source=bin/lib/pr-self-check.sh
command -v psc_check >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/pr-self-check.sh" 2>/dev/null || true
# shellcheck source=bin/lib/lead-gates-knobs.sh
command -v lgk_load >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/lead-gates-knobs.sh" 2>/dev/null || true

declare -g LGSC_OUT="" LGSC_BODY=""

_lgsc_safe() { printf '%s' "${1//\//_}" | tr -cd 'A-Za-z0-9._-'; }

lgsc_run() {
  local slug="$1" n="$2" head h12="${3:0:12}" root="${HARNESS:-${H:-}}" d safe out project repo bf tf ij tn tk base rc it il ir itn
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  LGSC_OUT=""; LGSC_BODY=""
  command -v lgk_load >/dev/null 2>&1 || return 2
  lgk_load
  [ "$LGK_PSC" = 1 ] || return 2
  command -v psc_check >/dev/null 2>&1 || return 2
  [ -n "$root" ] || return 2
  [ -r "${PR_SELF_CHECK_CATALOG:-$root/catalog/pr-self-check.tsv}" ] || return 2
  d=$(lgs_dir 2>/dev/null) || return 2
  safe=$(_lgsc_safe "$slug")
  out="$d/psc-$safe-$n-$h12"
  if [ -e "$out.rc" ]; then
    LGSC_OUT="$out"; LGSC_BODY="$d/psc-body-$safe-$n"
    rc=$(cat "$out.rc" 2>/dev/null)
    [ "$rc" = 2 ] && return 2
    return 0
  fi
  # Decided once per head per process: a check that cannot run is not retried
  # by the second gate.
  echo 2 > "$out.rc"
  project=$(awk -v r="$slug" '$1 !~ /^#/ && $2 == r {print $1; exit}' "${FLEET_CONF:-$root/fleet.conf}" 2>/dev/null)
  [ -n "$project" ] || return 2
  repo="${REPOS_ROOT:-/root/repos}/$project"
  [ -d "$repo/.git" ] || return 2
  bf="$d/psc-pr-$safe-$n.json"
  if command -v lgs_pr_body >/dev/null 2>&1; then
    lgs_pr_body "$slug" "$n" || return 2
    cp "$LGS_BODY_FILE" "$bf" 2>/dev/null || return 2
  else
    gh_rest GET "repos/$slug/pulls/$n" > "$bf" 2>/dev/null || return 2
  fi
  LGSC_BODY="$d/psc-body-$safe-$n"
  jq -r '.body // ""' "$bf" > "$LGSC_BODY" 2>/dev/null || return 2
  base=$(jq -r '.base.ref // empty' "$bf" 2>/dev/null)
  [ -n "$base" ] || return 2
  if ! git -C "$repo" cat-file -e "$head^{commit}" 2>/dev/null \
     || ! git -C "$repo" rev-parse -q --verify "origin/$base^{commit}" >/dev/null 2>&1; then
    git -C "$repo" fetch -q origin "$base" "$head" >/dev/null 2>&1 || return 2
  fi
  tf="$d/psc-ticket-$safe-$n"; : > "$tf"; ij="$d/psc-ticket-$safe-$n.json"; : > "$ij"; it=""; il=""; ir=""; itn=""
  tn=$(grep -oiE '(closes|fixes|resolves|refs|part of)[[:space:]]+#[0-9]+' "$LGSC_BODY" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
  if [ -n "$tn" ] && gh_rest GET "repos/$slug/issues/$tn" > "$ij" 2>/dev/null; then
    jq -r '.body // ""' "$ij" > "$tf" 2>/dev/null
    it=$(jq -r '.title // ""' "$ij" 2>/dev/null); il=$(jq -r '[.labels[]?.name] | join(",")' "$ij" 2>/dev/null)
    ir="$slug"; itn="$tn"
  fi
  tk=$(jq -r '.title // ""' "$bf" 2>/dev/null | sed -nE 's/^([A-Za-z]+-[0-9]+(\.[0-9]+)*):.*/\1/p')
  PR_SELF_CHECK_CATALOG="${PR_SELF_CHECK_CATALOG:-$root/catalog/pr-self-check.tsv}" PSC_PR_KEY="$tk" \
    PSC_TICKET_TITLE="$it" PSC_TICKET_LABELS="$il" PSC_TICKET_REPO="$ir" PSC_TICKET_N="$itn" \
    PSC_PR_REPO="$slug" PSC_PR_N="$n" PSC_PROJECT="$project" \
    psc_check "$repo" "origin/$base" "$head" "$LGSC_BODY" "$tf" > "$out" 2>/dev/null
  rc=$?
  echo "$rc" > "$out.rc"
  [ "$rc" = 2 ] && return 2
  LGSC_OUT="$out"
  return 0
}

lgsc_refusals() {
  [ -r "$LGSC_OUT" ] || return 0
  case "$1" in
    body)  sed -n 's/^REFUSE \(body-.*\)/\1/p' "$LGSC_OUT" ;;
    other) sed -n 's/^REFUSE //p' "$LGSC_OUT" | grep -v '^body-' ;;
    *)     sed -n 's/^REFUSE //p' "$LGSC_OUT" ;;
  esac
  return 0
}

lgsc_notes() {
  [ -r "$LGSC_OUT" ] || return 0
  sed -n 's/^NOTE \(body-[a-z0-9-]*: the body is missing .*\)/\1/p' "$LGSC_OUT"
  sed -n 's/^NOTE \(callers-not-ported: .*\)/\1/p' "$LGSC_OUT"
  sed -n 's/^NOTE \(project-21-upgrade: .*\)/\1/p' "$LGSC_OUT"
}

lgsc_hold() {
  local slug="$1" n="$2" head="$3" h12="${3:0:12}" out="$4" root="${HARNESS:-${H:-}}" st safe psf psh ps0 age d cf
  [ -n "$root" ] || { _lgt_log "$slug#$n @$h12: no harness root; self-check hold not kept"; return 11; }
  st="$root/state/lead-review-enqueue"; safe=$(_lgsc_safe "$slug")
  psf="$st/selfcheck-$safe-$n-$h12"
  psh=$(cksum < "$LGSC_BODY" 2>/dev/null | cut -d' ' -f1)
  mkdir -p "$st" 2>/dev/null
  [ -e "$psf" ] || date +%s > "$psf" 2>/dev/null
  ps0=$(head -1 "$psf" 2>/dev/null)
  if ! grep -qx "commented $psh" "$psf" 2>/dev/null; then
    d=$(lgs_dir 2>/dev/null) || d="${TMPDIR:-/tmp}"
    cf="$d/psc-comment-$safe-$n"
    if [ "$LGK_PSCMAX" -eq 0 ]; then
      # BH-5905: a 0-minute wait requests the review on this same tick.
      printf 'The pre-review self-check (`bin/pr-self-check.sh`, BH-5798) refused this PR body on head `%s`:\n\n%s\n\nThe lead review is requested now; the findings ride in its scope note.\n' \
        "$h12" "$(printf '%s\n' "$out" | sed 's/^/- /')" > "$cf"
    else
      printf 'The pre-review self-check (`bin/pr-self-check.sh`, BH-5798) refused this PR body on head `%s`, so no lead review is requested yet:\n\n%s\n\nFix the body (or the branch) and the next tick checks again. After %s minutes the lead review is requested anyway, with these findings in its notes.\n' \
        "$h12" "$(printf '%s\n' "$out" | sed 's/^/- /')" "$LGK_PSCMAX" > "$cf"
    fi
    if gh_rest POST "repos/$slug/issues/$n/comments" -F "body=@$cf" >/dev/null 2>&1; then
      echo "commented $psh" >> "$psf"
    else
      _lgt_log "$slug#$n @$h12: the self-check comment did not post (HTTP ${GH_REST_STATUS:-000}); next tick retries"
    fi
  fi
  age=$(( $(date +%s) - ${ps0:-0} ))
  if [[ "$ps0" =~ ^[0-9]+$ ]] && [ "$age" -lt $((LGK_PSCMAX * 60)) ]; then
    lgs_skip_once "$slug" "$n" "$head" selfcheck \
      "not requested: self-check refused ($(printf '%s' "$out" | tr '\n' ';' | cut -c1-300)) — held ${age}s of ${LGK_PSCMAX}m"
    return 11
  fi
  # Gates 7 and 8 both pass here when both kinds of rule refused: one line.
  _lgt_once "psc-bound-$safe-$n-$h12" "$slug#$n @$h12: self-check still refused after ${LGK_PSCMAX}m; starting anyway with the findings in the job notes"
  return 0
}
