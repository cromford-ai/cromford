# shellcheck shell=bash
# bin/blocked-resolver.d/bh-8896-fix-round-tree.sh — BH-8896: a fix round
# runs its agent only in the PR's own tree.
#
# WHY. FXR-1465 ran on a reused pool machine that still held TK-3496's build
# dir, and the round's record carried that build's reviewed-sha.
#
# WHAT. This fragment loads frt_check from bin/lib/fix-round-tree.sh.
# br_fix_round calls it before any agent call; a tree that is not the PR's is
# setup-blocked with no rung counted. If the lib is missing, frt_check is not
# defined and br_fix_round runs as before (fail-open, like every fragment).
. "${H}/bin/lib/fix-round-tree.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/../lib/fix-round-tree.sh" 2>/dev/null || true

# THE ADOPT READS THE POOL ROW (BH-8896, comment 6558202642). A pool machine
# posts its own finish, and br_fix_adopt can run before the hub reap closes the
# FXR pool row, so the adopt asks that row first. The hub reap closes a round
# whose record carried another job's build `failed` with a reason that starts
# `wrong-tree:` (config/fly-pool.d/3400). Such a round does not count against
# the fix rung: br_fix_adopt saves its record, wins the CAS, and then calls
# frt_refund instead of the rung the round answered.
#
# frt_adopt_gate <project> <rkey> <reason> <cap-key> <fix-row-json>
#   rc 0 adopt now (FRT_WRONG=1 when the pool row is failed wrong-tree);
#   rc 1 hold: the pool row is still queued or claimed, nothing is taken and
#   the next tick reads it again. A row that cannot be read is rc 0 with one
#   line: the adopt runs as before (fail-open, so a queue outage never holds
#   every adopt). The read is frp_put's (bin/lib/fix-round-pool.sh).
frt_adopt_gate() {
  local p="$1" rkey="$2" reason="$3" ck="$4" row="$5" id ck8 key resp st why
  FRT_WRONG=0
  id=$(printf '%s' "$row" | jq -r '.id // empty' 2>/dev/null)
  ck8=$(printf '%s' "$ck" | sha256sum 2>/dev/null | cut -c1-8)
  [ -n "$id" ] && [ "${#ck8}" = 8 ] || return 0
  key="FXR-$id-$ck8"
  command -v _jobs_req >/dev/null 2>&1 \
    && resp=$(_jobs_req GET "/api/queue?project=$p&key=$key&limit=1" 2>/dev/null) \
    && IFS=$'\t' read -r st why < <(jq -r --arg k "$key" 'if (.queue | type) != "array" then error("no queue") else
         ([.queue[] | select(.ticket_key == $k)][0] // {}) | [(.status // "none"),
           ((.reason // "") | tostring | (split("\n")[0] // "") | if . == "" then "-" else .[0:200] end)] end | @tsv' <<<"$resp" 2>/dev/null)
  if [ -z "${st:-}" ]; then
    say "$p/$rkey [$reason]: adopt: pool row $key unreadable — adopted as before"
    return 0
  fi
  case "$st" in
    queued|claimed)
      say "$p/$rkey [$reason]: adopt held: pool row $key is $st, the hub reap has not run — re-read next tick, nothing taken"
      return 1 ;;
    failed) case "$why" in "wrong-tree:"*) FRT_WRONG=1 ;; esac ;;
  esac
  return 0
}

# frt_refund <project> <cap-key> <rkey> <reason> <pr-url> <fix-row-id> <result>
#   The round was wrong-tree: ONE record write, fixround_refunds +1 (br_fix_cap
#   adds it to every cap) and one fix-round-wrong-tree attempt. A setup-blocked
#   or box-paused round spent nothing, so nothing is refunded. A write that
#   fails is one line and no retry: a lost refund is the conservative side.
frt_refund() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" id="$6" res="$7" key ck8
  case "$res" in
    "setup-blocked "*|"box-paused "*)
      say "$p/$rkey [$reason]: wrong-tree round $id: nothing was spent, nothing refunded"
      return 0 ;;
  esac
  ck8=$(printf '%s' "$ck" | sha256sum 2>/dev/null | cut -c1-8); key="FXR-$id-$ck8"
  if ! br_json_edit "$p" "$ck" '.fixround_refunds = ((.fixround_refunds // 0) + 1)
      | .attempts += [{at:$t, action:"fix-round-wrong-tree", reason:$r, url:$u,
          detail:("pool row " + $k + " reaped wrong-tree; this round does not count against the fix rung; the ladder offers the fix round again")}]
      | .updated = $t' --arg t "$(STAMP)" --arg r "$reason" --arg u "$url" --arg k "$key"; then
    say "$p/$rkey [$reason]: wrong-tree round $id: the refund was not written — not retried"
    return 0
  fi
  rm -f "$ST/$p/$ck.setup-alerted" 2>/dev/null
  br_event resolver_fix_wrong_tree "$p" "$ck" "$reason" "pool row $key reaped wrong-tree; fix round $id refunded"
  say "$p/$rkey [$reason]: fix round $id ran on a wrong tree (pool row $key) — refunded, the ladder offers the fix round again"
  return 0
}
