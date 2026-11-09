#!/bin/bash
# bin/lib/verdict-status.sh — BH-3348: publish the `lead-verdict` GitHub commit
# status on the exact sha a verdict binds to. Sourced, never executed.
#
# WHY. Mergify merged #3307 at 4f4b3f914 while the only lead verdict on it
# (#176) bound af9842fb1, a commit that never reached GitHub: nothing in
# .mergify.yml asked for a verdict, so anyone who added `merge-queue` and
# posted `@Mergifyio queue` landed a head no review covered. The cromford
# conf now makes both queues' queue_conditions require `check-success=lead-verdict`
# (config/mergify/repos/cromford.conf, `status_check=`), and this is the
# one writer of that status. A commit status is keyed by (repo, sha, context),
# so a push leaves the new head with none: the gate is head-bound by
# construction.
#
# TWO PUBLISHERS, both of which already hold a head-bound verdict:
#   bin/lead-verdict.sh post   (lead|human rows) success on MERGE /
#                              MERGE-WITH-NOTES, failure on BLOCK
#   mc_enqueue_mergify         (bin/lib/mc/queue.sh) success on the head the
#                              conductor is about to enqueue, after its own
#                              head-bound jobs-ledger verdict
#
# vs_publish <owner/repo> <sha> <success|failure|pending> <description> [<https target url>]
#   pending (BH-8476): bin/lead-verdict.sh retract, when no row stands on the
#   sha any more or the one left is withheld for a human verdict. Mergify needs
#   success, so pending holds the head as failure does, without a verdict.
#   rc 0  GitHub answered 2xx (201): the status is on that sha.
#   rc 1  anything else; ONE stderr line names GH_REST_STATUS / GH_REST_REASON,
#         the token kind (token=app|pat|gh-auth|other, never the value) and
#         GitHub's message (GH_REST_MESSAGE) when it sent one (BH-8848).
#   rc 2  a bad argument (slug, 40-hex sha, state); nothing is sent.
# The description is cut to 140 characters (GitHub's limit), never refused. A
# target url that is not https:// is dropped. The identity is the App token
# when this box mints one (gh_auth_for), else the caller's own gh auth (the
# lead's Mac); the token lives only for this call and is never printed.
# BH-8848: on a box that mints (gh_auth_armed), the POST goes ONLY on an App
# installation token (ghs_*). gh-token.sh prints the PAT when a mint fails, so
# a token that is not ghs_* is a failed mint: one re-mint, then ONE line
# `vs_publish: no App token for <slug>; ...`, rc 1 and no POST.
# A 403/429 that gh_rest classed rate-limit, with a Retry-After of 1..N seconds
# (N = VS_RETRY_AFTER_MAX_S, 0 = never), is sent once more after that wait.
#
# The context defaults to `lead-verdict` and LEAD_VERDICT_CONTEXT overrides it;
# vs_context prints the one in force, for the readers that must skip it
# (it is a status, not a check run: autoenqueue G4, the stuck-batch pass).
# BH-9039: the conductor publishes `harness-verdict` (vs_builder_context) for a
# builder-only clearance on every repo, and `lead-verdict` only after a lead or
# human MERGE row (lr_clear_context). cromford's queue accepts either
# (status_check_any=). vs_clear_row reads the clearance on a head by the same
# rule as the queue.
#
# BH-9287: WHICH APP WRITES THE STATUS. A lane-run machine's default App is the
# builders App, which has no "Commit statuses" permission, so every conductor
# publish there answered 403. A box that holds a STATUS App profile
# (<env dir>/github-app-status.env, written by fly/lane-run-entrypoint.sh from
# GH_APP_STATUS_ID + GH_APP_STATUS_PRIVATE_KEY) mints the status write from
# that profile (vs_status_profile, vs_status_profile_ready). Any other box,
# the hub included, mints as before, byte for byte.
# vs_mergify_names <owner/repo> <context> tells the conductor's alert whether
# the repo's .mergify.yml waits on the context at all (rc 0 yes, 1 no or no
# file, 75 unreadable); vs_app_name prints the slug of the App that mints
# here (GET /app, through bin/gh-token.sh --app-slug).
#
# vs_lead_desc <verdict-row-json> <desc> (BH-5352) prefixes the description of a
# row a participant machine wrote (auth=participant) with `lead review by <name>: `.
#
# WHO MAY PUBLISH SUCCESS (BH-3683). Both publishers ask bin/lib/lead-authority.sh
# (la_decide) first, loaded below: on a repo with live lead_protected_paths rows,
# a PR touching a protected path, or a repo whose lane authority is revoked,
# needs a --source human verdict before success is published. A failure (BLOCK)
# is never asked. vs_publish itself does not decide; its callers do.
# gh-rest: no-graphql
command -v gh_rest >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/gh-rest.sh" ] && . "${BASH_SOURCE[0]%/*}/gh-rest.sh"; }
command -v gh_auth_for >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/gh-app-auth.sh" ] && . "${BASH_SOURCE[0]%/*}/gh-app-auth.sh"; }
command -v la_decide >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/lead-authority.sh" ] && . "${BASH_SOURCE[0]%/*}/lead-authority.sh"; }

vs_context() { printf '%s\n' "${LEAD_VERDICT_CONTEXT:-lead-verdict}"; }

# vs_builder_context (BH-9039) — the context a builder-only clearance publishes
#   (lr_clear_context, bin/lib/lead-required.sh). A contract name shared with
#   cromford's .mergify.yml (status_check_any=), so no env override.
vs_builder_context() { printf '%s\n' harness-verdict; }

# vs_clear_row <combined-status.json> (BH-9039) — the queue clearance on a
#   head, the same rule as cromford's queue_conditions
#   (`check-success~=^(lead-verdict|harness-verdict)$` plus a
#   `-check-failure=` veto per name). L = the vs_context status, B = the
#   vs_builder_context status. L failure or error: L (a lead BLOCK vetoes).
#   Else L success: L. Else B success: B. Else L when present, else B.
#   Prints `<state>\t<updated_at>\t<description>` of that status, or
#   `-\t-\t` when neither is present. rc 2 (nothing printed) when the body
#   has no statuses array or jq is missing: never read as "absent".
vs_clear_row() {
  command -v jq >/dev/null 2>&1 || return 2
  jq -er --arg l "$(vs_context)" --arg b "$(vs_builder_context)" '
    (.statuses | if type == "array" then . else error("statuses") end) as $s
    | ([$s[] | select(.context == $l)][0]) as $L
    | ([$s[] | select(.context == $b)][0]) as $B
    | (if $L != null and ($L.state == "failure" or $L.state == "error") then $L
       elif $L != null and $L.state == "success" then $L
       elif $B != null and $B.state == "success" then $B
       elif $L != null then $L
       else $B end) as $w
    | if $w == null then "-\t-\t"
      else "\($w.state // "?")\t\($w.updated_at // $w.created_at // "?")\t\(($w.description // "") | gsub("[\t\n]"; " "))" end' \
    "${1:-/nonexistent}" 2>/dev/null || return 2
}

# vs_status_profile (BH-9287) — the gh-token.sh App profile a status write
#   mints from on a box that holds it. A contract name shared with
#   fly/lane-run-entrypoint.sh, which writes env/github-app-status.env, so no
#   env override (the vs_builder_context precedent).
vs_status_profile() { printf '%s\n' status; }

# _vs_env_dir — the env dir gh-token.sh reads: harness_env_dir when it is
#   loaded, else <harness>/env (the gh_auth_armed rule). rc 1 and nothing
#   printed with no harness root.
_vs_env_dir() {
  local root="${_GHAA_H:-${HARNESS:-${H:-}}}"
  [ -n "$root" ] || return 1
  if declare -F harness_env_dir >/dev/null 2>&1; then harness_env_dir "$root"; else printf '%s\n' "$root/env"; fi
}

# vs_status_profile_ready (BH-9287) — rc 0 when this box holds the status
#   profile: <env dir>/github-app-<vs_status_profile>.env is readable. rc 1
#   with no harness root (the BH-2613 lib-root contract).
vs_status_profile_ready() {
  local d
  d=$(_vs_env_dir) && [ -n "$d" ] || return 1
  [ -r "$d/github-app-$(vs_status_profile).env" ]
}

# vs_app_name (BH-9287) — the slug of the App a status write mints from on
#   this box (GET /app on its JWT: bin/gh-token.sh [--app status] --app-slug).
#   rc 1 and nothing printed when the box does not mint or GitHub did not
#   answer: a name is never guessed.
vs_app_name() {
  local h="${_GHAA_H:-${HARNESS:-${H:-}}}" p="" out
  [ -n "$h" ] && [ -x "$h/bin/gh-token.sh" ] || return 1
  vs_status_profile_ready && p=$(vs_status_profile)
  out=$("$h/bin/gh-token.sh" ${p:+--app "$p"} --app-slug 2>/dev/null) || return 1
  out=$(head -n 1 <<<"$out")
  [[ $out =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  printf '%s\n' "$out"
}

# vs_mergify_names <owner/repo> <context> (BH-9287) — does the repo's
#   .mergify.yml wait on <context>? rc 0 when a success condition
#   (check-success, check-success-or-neutral, status-success; `=` or `~=`) in
#   any section holds <context> as a whole token: bounded on both sides by a
#   character outside [A-Za-z0-9_-] or the end of the value. A comment line,
#   a trailing ` # ...` comment, a negated `-check-success=` and a
#   `check-failure` veto do not count. rc 1 = no such condition, or no
#   .mergify.yml (404). rc 75 = the file could not be read, or jq/base64 are
#   missing: the caller treats that as "names it", so an outage never hides
#   an alert. The read goes through gh_policy_read (the conductor's
#   per-repo `mergify` cache entry) when it is loaded, else gh_rest.
vs_mergify_names() {
  local slug="${1:-}" ctx="${2:-}" t rc=0 body b64 yml
  [ -n "$slug" ] && [ -n "$ctx" ] || return 75
  command -v jq >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1 || return 75
  t=$(mktemp "${TMPDIR:-/tmp}/vs-mergify.XXXXXX") || return 75
  if command -v gh_policy_read >/dev/null 2>&1; then
    gh_policy_read "$slug" mergify "repos/$slug/contents/.mergify.yml" > "$t" || rc=$?
  elif command -v gh_rest >/dev/null 2>&1; then
    gh_rest GET "repos/$slug/contents/.mergify.yml" > "$t" || rc=$?
  else
    rc=75
  fi
  body=$(cat "$t" 2>/dev/null); rm -f "$t"
  case "$rc" in
    0) ;;
    44) return 1 ;;
    *) [ "${GH_REST_STATUS:-}" = 404 ] && return 1; return 75 ;;
  esac
  b64=$(jq -r '.content // empty' <<<"$body" 2>/dev/null) || return 75
  [ -n "$b64" ] || return 75
  yml=$(printf '%s' "$b64" | tr -d '\n\r ' | base64 -d 2>/dev/null) || yml=""
  [ -n "$yml" ] || yml="$b64"
  awk -v ctx="$ctx" -v q="'" '
    function tok(v,   s, i, a, b) {
      s = v
      while ((i = index(s, ctx)) > 0) {
        a = (i == 1) ? "" : substr(s, i - 1, 1)
        b = substr(s, i + length(ctx), 1)
        if (a !~ /[-A-Za-z0-9_]/ && b !~ /[-A-Za-z0-9_]/) return 1
        s = substr(s, i + 1)
      }
      return 0
    }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      while (match(line, /(^|[^-A-Za-z0-9_])(check-success-or-neutral|check-success|status-success)[[:space:]]*~?=[[:space:]]*/)) {
        v = substr(line, RSTART + RLENGTH)
        line = v
        c = substr(v, 1, 1)
        if (c == "\"" || c == q) { v = substr(v, 2); i = index(v, c); if (i) v = substr(v, 1, i - 1) }
        else { sub(/["\047][[:space:]]*$/, "", v); sub(/[[:space:]]+$/, "", v) }
        if (v != "" && tok(v)) { found = 1; exit }
      }
    }
    END { exit found ? 0 : 1 }' <<<"$yml"
}

# vs_lead_desc <verdict-row-json> <desc> — BH-5352: the description for the
#   row the worker recorded. A row with auth=participant and a reviewer prints
#   `lead review by <reviewer>: <desc>`; any other row, unparseable JSON or no
#   jq prints <desc> as given. Always rc 0: the prefix is cosmetic, and refusing
#   to publish would hold a recorded MERGE.
vs_lead_desc() {
  local row="${1:-}" desc="${2:-}" who=""
  command -v jq >/dev/null 2>&1 \
    && who=$(printf '%s' "$row" | jq -r 'if (.auth? == "participant") and ((.reviewer? // "") | type == "string" and length > 0) then .reviewer else empty end' 2>/dev/null)
  if [ -n "$who" ]; then printf 'lead review by %s: %s\n' "$who" "$desc"; else printf '%s\n' "$desc"; fi
  return 0
}

# _vs_token_kind — the kind of the GH_TOKEN in force, from its prefix only.
_vs_token_kind() {
  case "${GH_TOKEN:-}" in
    '') echo gh-auth ;; ghs_*) echo app ;; ghp_*|github_pat_*) echo pat ;; *) echo other ;;
  esac
}

# _vs_sleep <seconds> — the retry wait; the seam a test overrides.
_vs_sleep() { sleep "$1"; }

# _vs_retry_max — VS_RETRY_AFTER_MAX_S, the longest Retry-After vs_publish
#   waits once. Resolved through lib_env_apply verdict-status (the settings row
#   lib.verdict-status.vs_retry_after_max_s, catalog/lanes.d/_lib.verdict-status.json)
#   in a subshell, so the caller's env is untouched. 30 is the code fallback
#   for that row; a value that is not a whole number is 30.
_vs_retry_max() {
  local v lib="${BASH_SOURCE[0]%/*}"
  v=$(
    command -v lib_env_apply >/dev/null 2>&1 || { [ -r "$lib/lane-gate.sh" ] && . "$lib/lane-gate.sh" >/dev/null 2>&1; }
    command -v lib_env_apply >/dev/null 2>&1 && { lib_env_apply verdict-status >/dev/null 2>&1 || true; }
    printf '%s' "${VS_RETRY_AFTER_MAX_S:-}"
  )
  case "$v" in ''|*[!0-9]*) v=30 ;; esac
  echo $((10#$v))
}

vs_publish() {
  local slug="${1:-}" sha="${2:-}" state="${3:-}" desc="${4:-}" url="${5:-}" rc=0
  # Local: gh_auth_for exports into THIS scope, and the caller's identity is
  # back the moment this returns (the gh_rest C2 rule).
  local GH_TOKEN="${GH_TOKEN:-}"
  local inh="${GH_TOKEN:-}" ra="" first="" msg=""
  local -a a
  [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "vs_publish: repo must be owner/name, got '$slug'" >&2; return 2; }
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "vs_publish: sha must be 40 lowercase hex, got '$sha'" >&2; return 2; }
  case "$state" in success|failure|pending) ;; *) echo "vs_publish: state must be success, failure or pending, got '$state'" >&2; return 2 ;; esac
  command -v gh_rest >/dev/null 2>&1 || { echo "vs_publish: bin/lib/gh-rest.sh is not loaded; $(vs_context) not published on ${sha:0:12}" >&2; return 1; }
  a=(-f "state=$state" -f "context=$(vs_context)" -f "description=${desc:0:140}")
  case "$url" in https://*) a+=(-f "target_url=$url") ;; esac
  # BH-9287: a box with the status profile mints from it. `local` only then,
  # so a caller's own GH_APP_PROFILE (exported or not) is untouched otherwise
  # and is back the moment this returns.
  if vs_status_profile_ready; then
    local GH_APP_PROFILE
    GH_APP_PROFILE=$(vs_status_profile); export GH_APP_PROFILE
  fi
  if declare -F gh_auth_armed >/dev/null 2>&1 && gh_auth_armed; then
    # BH-8848: an armed box posts as the App or not at all; one re-mint.
    if ! gh_auth_for "$slug" || [[ "${GH_TOKEN:-}" != ghs_* ]]; then
      GH_TOKEN="$inh"
      if ! gh_auth_for "$slug" || [[ "${GH_TOKEN:-}" != ghs_* ]]; then
        echo "vs_publish: no App token for $slug; $(vs_context)=$state NOT published on $slug@${sha:0:12}" >&2
        return 1
      fi
    fi
  else
    command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$slug" || true; }
  fi
  # ${a[@]+…}: bash < 4.4 (macOS /bin/bash 3.2) calls an empty array unbound under set -u (BH-3565).
  gh_rest POST "repos/$slug/statuses/$sha" ${a[@]+"${a[@]}"} >/dev/null || rc=$?
  case "$rc:${GH_REST_STATUS:-000}" in
    0:2*) return 0 ;;
  esac
  # One retry on a secondary rate limit, only with GitHub's own Retry-After.
  case "${GH_REST_STATUS:-000}:${GH_REST_REASON:-}:${GH_REST_QUOTA_RETRY_AFTER:-}" in
    403:rate-limit:[0-9]*|429:rate-limit:[0-9]*)
      ra=$((10#$GH_REST_QUOTA_RETRY_AFTER))
      if [ "$ra" -ge 1 ] && [ "$ra" -le "$(_vs_retry_max)" ]; then
        first="HTTP $GH_REST_STATUS, $GH_REST_REASON; token=$(_vs_token_kind)${GH_REST_MESSAGE:+; GitHub: $GH_REST_MESSAGE}"
        _vs_sleep "$ra"
        rc=0
        gh_rest POST "repos/$slug/statuses/$sha" ${a[@]+"${a[@]}"} >/dev/null || rc=$?
        case "$rc:${GH_REST_STATUS:-000}" in
          0:2*) echo "vs_publish: $(vs_context)=$state published on $slug@${sha:0:12} after one retry ($first; Retry-After ${ra}s)" >&2
                return 0 ;;
        esac
        msg="; retried once after ${ra}s"
      fi ;;
  esac
  echo "vs_publish: $(vs_context)=$state NOT published on $slug@${sha:0:12} (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+, $GH_REST_REASON}; token=$(_vs_token_kind)${GH_REST_MESSAGE:+; GitHub: $GH_REST_MESSAGE}$msg)" >&2
  return 1
}
