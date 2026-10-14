#!/bin/bash
# bin/lib/queue-batch-only.sh — is this repo's test corpus run ONLY in its
# merge-queue batch? (CI cost cut, 2026-09-24.) Sourced, never executed.
#
#   mc_queue_batch_only <owner/repo>   rc 0 = yes OR could not tell (fails
#                                      closed), rc 1 = read, and no
#
# cromford tests each tree exactly once: an ordinary PR runs the fast
# checks, and the corpus, the SPA and the jobs worker run only on Mergify's
# batch draft. Its .mergify.yml says so in its own terms — merge_conditions ask
# for checks that queue_conditions do not. On such a repo a green PR head is a
# fast-checks green and nothing more. Since BH-2199 no path merges such a repo
# around its queue, so the one live reader is bin/blocked-resolver.sh's
# green-at-head guard: on a batch-only repo a `queue-ejected-twice` park is
# released only by a green BATCH carrying the PR, never by the head's green.
#
# The read is the one mc_queue_mergify_enabled already makes (the policy cache
# key `mergify`, the contents endpoint), so on a warm cache it costs nothing.
# IT FAILS CLOSED (2026-09-25). A config that cannot be read (403, an outage,
# an `unknown` provider, content that does not decode to a queue_rules file, a
# reader not loaded) answers YES: "could not tell" is never evidence that the
# PR head ran the corpus. Only a repo known not to be on Mergify, or whose
# config was read and splits no check, answers no.
[ -n "${_QUEUE_BATCH_ONLY_LOADED:-}" ] && return 0
_QUEUE_BATCH_ONLY_LOADED=1

# mc_queue_batch_only_yml — read .mergify.yml text on stdin; rc 0 when some
# check-success name in a merge_conditions list is absent from every
# queue_conditions list. Pure, so a suite drives it on literal YAML.
mc_queue_batch_only_yml() {
  awk '
    function name(s) {
      sub(/.*check-success[[:space:]]*=[[:space:]]*/, "", s)
      gsub(/["\047]/, "", s); sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^[[:space:]]*queue_conditions:/ { sec = "q"; next }
    /^[[:space:]]*merge_conditions:/ { sec = "m"; next }
    /^[[:space:]]*[A-Za-z_]+:/       { sec = "" }
    sec != "" && /check-success/     { n = name($0); if (sec == "q") Q[n] = 1; else M[n] = 1 }
    END { for (k in M) if (!(k in Q)) { found = 1 }; exit(found ? 0 : 1) }'
}

mc_queue_batch_only() {
  local slug="$1" b64 yml prov
  # FAIL CLOSED: every "could not tell" below is rc 0. Only a repo whose
  # provider is READ as something other than mergify/unknown, or whose config
  # is READ and splits no check, answers no.
  [ -n "$slug" ] || return 0
  command -v mc_queue_provider >/dev/null 2>&1 || return 0
  prov=$(mc_queue_provider "$slug")
  case "$prov" in
    mergify) ;;
    unknown|unloaded|'') return 0 ;;
    *) return 1 ;;
  esac
  command -v mc_policy_get >/dev/null 2>&1 || return 0
  mc_policy_get b64 "$slug" mergify "repos/$slug/contents/.mergify.yml" || return 0
  b64=$(jq -r '.content // empty' <<<"$b64" 2>/dev/null) || return 0
  [ -n "$b64" ] || return 0
  yml=$(printf '%s' "$b64" | tr -d '\n\r ' | base64 -d 2>/dev/null) || yml=""
  [ -n "$yml" ] || yml="$b64"
  # The provider is mergify only when .mergify.yml declares queue_rules, so a
  # text without it is not the file we were told about: could not tell.
  grep -q '^[[:space:]]*queue_rules:' <<<"$yml" || return 0
  printf '%s\n' "$yml" | mc_queue_batch_only_yml
}
