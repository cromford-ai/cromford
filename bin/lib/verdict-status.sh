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
# vs_publish <owner/repo> <sha> <success|failure> <description> [<https target url>]
#   rc 0  GitHub answered 2xx (201): the status is on that sha.
#   rc 1  anything else; ONE stderr line names GH_REST_STATUS / GH_REST_REASON.
#   rc 2  a bad argument (slug, 40-hex sha, state); nothing is sent.
# The description is cut to 140 characters (GitHub's limit), never refused. A
# target url that is not https:// is dropped. The identity is the App token
# when this box mints one (gh_auth_for), else the caller's own gh auth (the
# lead's Mac); the token lives only for this call and is never printed.
#
# The context defaults to `lead-verdict` and LEAD_VERDICT_CONTEXT overrides it;
# vs_context prints the one in force, for the readers that must skip it
# (it is a status, not a check run: autoenqueue G4, the stuck-batch pass).
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

vs_publish() {
  local slug="${1:-}" sha="${2:-}" state="${3:-}" desc="${4:-}" url="${5:-}" rc=0
  # Local: gh_auth_for exports into THIS scope, and the caller's identity is
  # back the moment this returns (the gh_rest C2 rule).
  local GH_TOKEN="${GH_TOKEN:-}"
  local -a a
  [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "vs_publish: repo must be owner/name, got '$slug'" >&2; return 2; }
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "vs_publish: sha must be 40 lowercase hex, got '$sha'" >&2; return 2; }
  case "$state" in success|failure) ;; *) echo "vs_publish: state must be success or failure, got '$state'" >&2; return 2 ;; esac
  command -v gh_rest >/dev/null 2>&1 || { echo "vs_publish: bin/lib/gh-rest.sh is not loaded; $(vs_context) not published on ${sha:0:12}" >&2; return 1; }
  a=(-f "state=$state" -f "context=$(vs_context)" -f "description=${desc:0:140}")
  case "$url" in https://*) a+=(-f "target_url=$url") ;; esac
  command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$slug" || true; }
  # ${a[@]+…}: bash < 4.4 (macOS /bin/bash 3.2) calls an empty array unbound under set -u (BH-3565).
  gh_rest POST "repos/$slug/statuses/$sha" ${a[@]+"${a[@]}"} >/dev/null || rc=$?
  case "$rc:${GH_REST_STATUS:-000}" in
    0:2*) return 0 ;;
  esac
  echo "vs_publish: $(vs_context)=$state NOT published on $slug@${sha:0:12} (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+, $GH_REST_REASON})" >&2
  return 1
}
