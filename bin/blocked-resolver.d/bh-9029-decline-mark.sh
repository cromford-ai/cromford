# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9029-decline-mark.sh — BH-9029: a standing verdict
# decline is not retried every tick.
#
# WHY. On 2026-11-03 PR #8999 reached rung rebuild-fresh on every tick, and
# every tick br_supersede_guard ended `SUPERSEDE DECLINED (verdict): a
# lead/human MERGE-WITH-NOTES verdict stands on 9819485e`. Nothing that answer
# read could change on its own, and the same 330 s run repeated each tick.
#
# THE MARK. When the guard declines on a verdict (either verdict arm: any
# lead/human verdict on the current head, or a MERGE/MERGE-WITH-NOTES on the
# head this lane's fix round pushed or pushed over), bdm_set writes
#   .decl_mark = {url, head, vhead, vrow, vword, kind, reason, ladder, why, logged}
# on the ticket's record. `head` is the PR head, `vhead` the head the verdict
# stands on, `vrow`/`vword` the verdict row id and word, `ladder` the counters
# "<mechanicals>/<fixrounds>/<fixround_bonus>/<rebuilds>".
#
# THE SKIP. bdm_skip, at the top of br_one, answers rc 0 (the row takes no rung
# this tick, br_one rc 3) while the same row id with the same word still stands
# on `vhead`, the PR is still on `head`, the reason and the ladder are the same,
# and `head` is not in noop_heads (BH-4149). One line per episode; the decline
# page (br_sup_alert) still fires after BR_SUPERSEDE_DECLINE_ALERT_SECS; a
# conductor park is released, as the decline released it. Anything that moved
# clears the mark with one line and the row runs as before. A head or verdict
# read that fails keeps the mark and runs the row as before (fail closed is
# the guard's job, not this skip's).
#
# Call sites, one line each in the driver:
#   br_supersede_guard, the two verdict arms -> bdm_set
#   br_one, after the fix-round adoption     -> bdm_skip (rc 0: br_one rc 3)
# BR_OPT_OFF=bh-9029-decline-mark does not source this file; each call site
# then does what it did before.

# bdm_set <project> <cap-key> <reason> <pr-url> <pr-head> <verdict-head> <kind> <why>
#   Writes the mark. Nothing in observe mode; nothing when the verdict row
#   cannot be read again (the decline then repeats next tick, as before).
bdm_set() {
  local p="$1" ck="$2" reason="$3" url="$4" cur="$5" vh="$6" kind="$7" why="$8"
  local slug num line
  [ "${OBSERVE:-0}" = 1 ] && return 0
  command -v vd_standing >/dev/null 2>&1 || return 0
  slug=$(br_slug_of_url "$url") || return 0
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 0
  line=$(vd_standing "$slug" "$num" "$vh") || return 0
  br_sup_write "$p" "$ck" \
    '.decl_mark = {url:$u, head:$h, vhead:$vh, vrow:$vr, vword:$vw, kind:$k, reason:$r,
                   ladder:("\(.mechanicals // 0)/\(.fixrounds // 0)/\(.fixround_bonus // 0)/\(.rebuilds // 0)"),
                   why:$w, logged:false}' \
    --arg u "$url" --arg h "$cur" --arg vh "$vh" --arg vr "$(cut -f3 <<<"$line")" \
    --arg vw "$(cut -f1 <<<"$line")" --arg k "$kind" --arg r "$reason" --arg w "$why" \
    || say "$p/$ck: the decline mark was not written — the guard runs again next tick"
  return 0
}

# bdm_clear <project> <rkey> <reason> <cap-key> <why> — one line, mark removed.
bdm_clear() {
  local p="$1" rkey="$2" reason="$3" ck="$4" why="$5"
  say "$p/$rkey [$reason]: decline mark cleared: $why — the row runs this tick"
  [ "${OBSERVE:-0}" = 1 ] && return 0
  br_sup_write "$p" "$ck" 'del(.decl_mark)' \
    || say "$p/$rkey: the decline mark was not removed — it is checked again next tick"
  return 0
}

# bdm_skip <src> <project> <rkey> <cap-key> <reason> <pr-url> <record-json>
#   rc 0 skip (no rung this tick); rc 1 run the row as before.
bdm_skip() {
  local src="$1" p="$2" rkey="$3" ck="$4" reason="$5" url="${6:--}" st="${7:-}"
  local f mu mh mvh mvr mvw mk mr ml mw mlog lad noop oc slug num cur rc line
  # No fork for the rows with no mark, which is nearly all of them.
  case "$st" in *'"decl_mark"'*) ;; *) return 1 ;; esac
  f=$(jq -r '
      def s(x): (x // "") | tostring | gsub("[\t\n]"; " ") | if . == "" then "-" else . end;
      .decl_mark as $m
      | if ($m | type) != "object" then empty else
          [ s($m.url), s($m.head), s($m.vhead), s($m.vrow), s($m.vword), s($m.kind),
            s($m.reason), s($m.ladder), s($m.why), (if $m.logged == true then "1" else "0" end),
            "\(.mechanicals // 0)/\(.fixrounds // 0)/\(.fixround_bonus // 0)/\(.rebuilds // 0)",
            (if ([.noop_heads[]? | ascii_downcase] | index(($m.head // "") | ascii_downcase)) != null then "1" else "0" end),
            s(.outcome) ] | join("\t")
        end' <<<"$st" 2>/dev/null) || return 1
  [ -n "$f" ] || return 1
  IFS=$'\t' read -r mu mh mvh mvr mvw mk mr ml mw mlog lad noop oc <<<"$f"
  # A mark about another PR of this ticket is not this row's: no skip, no clear.
  [ "$mu" = "$url" ] || return 1
  if [ "$mr" != "$reason" ]; then bdm_clear "$p" "$rkey" "$reason" "$ck" "the reason changed ($mr -> $reason)"; return 1; fi
  if [ "$ml" != "$lad" ]; then bdm_clear "$p" "$rkey" "$reason" "$ck" "the ladder moved ($ml -> $lad)"; return 1; fi
  if [ "$noop" = 1 ]; then bdm_clear "$p" "$rkey" "$reason" "$ck" "the head is frozen in noop_heads (${mh:0:12}), so a BLOCK there no longer keeps the PR"; return 1; fi
  slug=$(br_slug_of_url "$url") || return 1
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 1
  cur=$(br_pr_field "$url" '.head.sha' "pr head (decline mark)"); rc=$?
  [ "$rc" = 0 ] || return 1
  cur=$(printf '%s' "$cur" | tr 'A-F' 'a-f')
  [ -n "$cur" ] || return 1
  if [ "$cur" != "$mh" ]; then bdm_clear "$p" "$rkey" "$reason" "$ck" "the PR head moved (${mh:0:12} -> ${cur:0:12})"; return 1; fi
  command -v vd_standing >/dev/null 2>&1 || return 1
  line=$(vd_standing "$slug" "$num" "$mvh"); rc=$?
  case "$rc" in
    0) if [ "$(cut -f3 <<<"$line")" != "$mvr" ] || [ "$(cut -f1 <<<"$line")" != "$mvw" ]; then
         bdm_clear "$p" "$rkey" "$reason" "$ck" "verdict row $mvr no longer stands on ${mvh:0:12} (now: $(cut -f1 <<<"$line") row $(cut -f3 <<<"$line"))"
         return 1
       fi ;;
    1) bdm_clear "$p" "$rkey" "$reason" "$ck" "verdict row $mvr no longer stands on ${mvh:0:12} (no verdict stands there now)"; return 1 ;;
    *) return 1 ;;
  esac
  if [ "$mlog" != 1 ]; then
    say "$p/$rkey [$reason]: SKIP decline-mark — SUPERSEDE DECLINED ($mk) stands: verdict row $mvr on ${mvh:0:12}, PR head ${mh:0:12}; not retried until the head, the verdict or the ladder changes"
    [ "${OBSERVE:-0}" = 1 ] || br_sup_write "$p" "$ck" '.decl_mark.logged=true' \
      || say "$p/$rkey: the decline mark's logged flag was not written — the skip line repeats next tick"
  fi
  br_sup_alert "$p" "$ck" "$rkey" "$reason" "$url" "$mh" "$mk" "$mw"
  # The decline released the conductor's park so the conductor reads the lead
  # verdict itself; the skip does the same, on the same terms as br_one's end.
  if [ "$src" = conductor ] && [ "${OBSERVE:-0}" = 0 ] && [ "$oc" != HELD ]; then
    mc_handoff_release "$slug#$num" "blocked-resolver/decline-mark"
  fi
  return 0
}
