# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9437-rereview.sh — a green fix push asks for a
# re-review of that head, and rebuild-fresh is held while it is pending
# (BH-9437 item 4; project-12#9: a PR was closed and rebuilt after a green fix push
# that no review had read). Sourced by the driver's blocked-resolver.d block;
# functions only, no exit.
#
# Record field `.rereview = {head, url, at, asked: ok|failed}` (written by the
# ask, read by the gate), and `.rereview_said = <head>` (one pending line per
# head). Both live and retire with the record.
# Knob: BR_REREVIEW_GATE (catalog/lanes.d/blocked-resolver.knobs.d/
# BR_REREVIEW_GATE.json), default 1; 0 = no ask and no hold, as before BH-9437.

# brlad_rereview_ask <p> <ck> <slug> <url> <pushed-sha> [<reason>] — the push
#   arm of br_fix_round, after br_fix_push_note. One `lead-verdict.sh request`
#   of the pushed head; a "request already exists" answer is asked=ok too. The
#   previous round's verify copy (bh-9437-verify-baseline.sh) is removed: the
#   push was green. Always rc 0: the push already happened.
brlad_rereview_ask() {
  local p="$1" ck="$2" slug="$3" url="$4" sha reason="${6:--}" on num asked=failed out
  sha=$(printf '%s' "${5:-}" | tr 'A-F' 'a-f')
  rm -f "$ST/$p/$ck.fix-verify.prev.txt" 2>/dev/null
  # BR_REREVIEW_GATE: catalog/lanes.d/blocked-resolver.knobs.d/BR_REREVIEW_GATE.json (fallback 1)
  on=$(brlad_knob BR_REREVIEW_GATE "${BR_REREVIEW_GATE:-1}" 1 0 1)
  [ "$on" = 1 ] || return 0
  # An outside contributor's PR is never rebuilt, so there is nothing to hold;
  # the project box's review lane reads it (BH-4668).
  [ "${BR_XPR_ACTIVE-}" = 1 ] && return 0
  num=$(mc_num_of_url "$url")
  [ -n "$slug" ] && [ -n "$num" ] && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 0
  if out=$("$H/bin/lead-verdict.sh" request "$slug" "$num" "$sha" 2>&1 </dev/null); then
    asked=ok
  else
    case "$out" in *"already exists"*) asked=ok ;; esac
  fi
  # shellcheck disable=SC2016  # $h $u $t $a are jq variables
  br_json_edit "$p" "$ck" '.rereview = {head:$h, url:$u, at:$t, asked:$a} | del(.rereview_said)' \
    --arg h "$sha" --arg u "$url" --arg t "$(STAMP)" --arg a "$asked" \
    || say "$p/$ck: the re-review ask of ${sha:0:12} could not be written to $(br_file "$p" "$ck") (BH-9437)"
  br_record "$p" "$ck" rereview-asked "$reason" "re-review of the pushed head ${sha:0:12} requested ($asked): $(head -1 <<<"$out" | cut -c1-160)" "" "$url"
  say "$p/$ck: re-review of the pushed head ${sha:0:12} requested ($asked) — rebuild-fresh is held while it is pending (BH-9437)"
  return 0
}

# brlad_rereview_gate <p> <ck> <rkey> <reason> <url> — br_rebuild_fresh, before
#   the cap check.
#   rc 0 the rebuild may go on: no ask on the record, another PR, the knob is
#        0, the head moved (a new push is a new event), a verdict stands on
#        the head, or the request ended with no verdict
#   rc 1 hold, nothing spent: the request is requested or running, or a read
#        this answer needs failed, or a failed ask was just sent again
brlad_rereview_gate() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" st rh ru on cur slug num vrc rows hit asked
  st=$(br_load "$p" "$ck")
  rh=$(printf '%s' "$st" | jq -r '.rereview.head // ""' 2>/dev/null)
  [ -n "$rh" ] || return 0
  ru=$(printf '%s' "$st" | jq -r '.rereview.url // ""' 2>/dev/null)
  [ -z "$ru" ] || [ "$ru" = "$url" ] || return 0
  # BR_REREVIEW_GATE: catalog/lanes.d/blocked-resolver.knobs.d/BR_REREVIEW_GATE.json (fallback 1)
  on=$(brlad_knob BR_REREVIEW_GATE "${BR_REREVIEW_GATE:-1}" 1 0 1)
  [ "$on" = 1 ] || return 0
  cur=$(br_pr_field "$url" .head.sha 'head sha' 2>/dev/null | tr 'A-F' 'a-f')
  if [ -z "$cur" ]; then
    say "$p/$rkey [$reason]: rebuild held — the PR head could not be read to check the re-review of ${rh:0:12}; retried next tick (BH-9437)"
    return 1
  fi
  [ "$cur" = "$rh" ] || return 0
  slug=$(br_slug_of_url "$url") || return 0
  num=$(mc_num_of_url "$url")
  vrc=1
  command -v vd_standing >/dev/null 2>&1 && { vd_standing "$slug" "$num" "$cur" >/dev/null 2>&1; vrc=$?; }
  case "$vrc" in
    0) return 0 ;;
    2) say "$p/$rkey [$reason]: rebuild held — the verdicts on ${cur:0:12} could not be read; retried next tick (BH-9437)"; return 1 ;;
  esac
  if ! command -v _jobs_req >/dev/null 2>&1; then
    say "$p/$rkey [$reason]: no jobs client on this box — the re-review of ${cur:0:12} cannot be checked; the rebuild goes on (BH-9437)"
    return 0
  fi
  if ! rows=$(_jobs_req GET "/api/lead-reviews?repo=$slug&status=requested,running" 2>/dev/null </dev/null) \
     || ! printf '%s' "$rows" | jq -e '.requests | type == "array"' >/dev/null 2>&1; then
    say "$p/$rkey [$reason]: rebuild held — the lead-review requests of $slug could not be read; retried next tick (BH-9437)"
    return 1
  fi
  hit=$(printf '%s' "$rows" | jq -r --arg pr "$num" --arg h "$cur" \
    '[.requests[] | select((.pr | tostring) == $pr and ((.head_sha // "") | ascii_downcase) == $h and (.status == "requested" or .status == "running"))] | first | .status // empty' 2>/dev/null)
  if [ -n "$hit" ]; then
    if [ "$(printf '%s' "$st" | jq -r '.rereview_said // ""' 2>/dev/null)" != "$cur" ]; then
      br_set_field "$p" "$ck" rereview_said "$cur" >/dev/null 2>&1 || true
      say "$p/$rkey [$reason]: rebuild held — the re-review of the pushed fix ${cur:0:12} is pending ($hit); nothing closed, nothing enqueued (BH-9437)"
    fi
    return 1
  fi
  asked=$(printf '%s' "$st" | jq -r '.rereview.asked // ""' 2>/dev/null)
  if [ "$asked" = failed ]; then
    brlad_rereview_ask "$p" "$ck" "$slug" "$url" "$cur" "$reason"
    say "$p/$rkey [$reason]: rebuild held — the re-review of ${cur:0:12} was not requested on the push tick; asked again (BH-9437)"
    return 1
  fi
  say "$p/$rkey [$reason]: the re-review of ${cur:0:12} ended with no verdict on the head — the rebuild goes on (BH-9437)"
  return 0
}
