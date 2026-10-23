#!/bin/bash
# tests/lib/gh-rest-stub.sh — ONE `gh api -i` answer for every fixture suite
# that drives a lane converted to bin/lib/gh-rest.sh (#783 and its siblings).
#
# WHY IT IS SHARED. gh_rest talks to `gh api -i`, so a stub has to answer with a
# STATUS LINE, a blank line and then the body — and a stub that answers anything
# else is read as rc 75 "GitHub did not answer", which silently turns every
# assertion in a suite into "the lane deferred". Sixteen suites drive
# bin/blocked-resolver.sh; sixteen hand-written copies of that envelope would
# drift, and a drifted copy goes GREEN by deferring.
#
# HOW A SUITE WIRES IT IN. The suite's own `gh` stub keeps its argv log and its
# non-REST arms and delegates the `-i` ones, first arm in its case:
#
#     case "$*" in
#       *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "$@" ;;
#       ...
#     esac
#
# THE FIXTURES IT READS are the ones those suites already wrote by hand, so
# wiring it in changes no scenario:
#
#   $T/prstate     OPEN | MERGED | CLOSED for the PR under test (default OPEN)
#   $T/prhead      head sha            $T/prbranch  head ref
#   $T/prtitle     PR title            $T/prbase    base ref (default main)
#   $T/prdiff      the unified diff the diff-Accept read answers with
#   $T/prcomments.json  the issue-comments ARRAY, or $T/prcomments, one body
#                  (served as a comment by cromford[bot], a verdict author)
#   $T/mergedprs   TSV url \t mergedAt \t headRefName \t title — BOTH the
#                  search/issues answer and the per-hit PR read are built from it
#   $T/reviews-<n>.json / $T/prreviews.json  a PR's reviews ARRAY (default [])
#   $T/openprs     the OPEN-PR LIST route's answer: the raw REST array
#                  harness_pr_list maps. A suite with no such file is answered
#                  the unknown-route way (a 2xx with no body = UNVERIFIABLE),
#                  which is what `gh api` printing nothing already meant.
#
# AND WHAT IT RECORDS, for the suites to assert on:
#   $T/closed.txt        one line per PATCH (the close)
#   $T/comments.txt      one line per comment POST
#   $T/comment-bodies.txt  the body FILE's contents, since the body never
#                        reaches argv
#   $T/reruns.txt        one line per actions rerun-failed-jobs POST
#
# PER-ROUTE STATUSES, for the rows that are ABOUT a GitHub that will not answer:
#   $T/st-pr $T/st-patch $T/st-comment $T/st-comments $T/st-search $T/st-rerun
#   $T/st-diff $T/st-prlist $T/st-reviews — write the HTTP status into the file; absent means 2xx.
#   $T/patch-noflip — the PATCH answers 2xx and the PR stays OPEN, so a close
#                  that was never made can be told apart from one that was.
#
# A CLOSE IS REMEMBERED IN $T/closed.txt, never by rewriting $T/prstate: other
# scripts in the same scratch harness read that file too, and a stub that edited
# it would change a scenario it was only meant to answer. Reading the memory back
# out of the close record also means a suite's own reset (`: > $T/closed.txt`)
# resets the stub, so no stub state outlives the scenario that made it — which is
# what gh_rest_close needs, since it only answers 0 when a FRESH read says closed.

_ghs_send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "${2:-}"; return 0; }
_ghs_st()   { cat "${GHT}/st-$1" 2>/dev/null || printf '%s' "$2"; }
_ghs_f()    { cat "${GHT}/$1" 2>/dev/null; }

# _ghs_prnum <argv string> — the number out of .../pulls/<n> or .../issues/<n>.
_ghs_prnum() {
  local p="$1"
  case "$p" in
    *"/pulls/"*)  p="${p##*/pulls/}" ;;
    *"/issues/"*) p="${p##*/issues/}" ;;
    *) printf ''; return 0 ;;
  esac
  p="${p%%/*}"; p="${p%% *}"
  printf '%s' "$p"
}

# _ghs_ref <argv string> — the API path repos/<owner>/<repo>/pulls/<n>, which is
# what "which PR is this" means here: two projects in one fixture both have a #9.
_ghs_ref() {
  local p="$1"
  case "$p" in *"repos/"*) p="repos/${p##*repos/}" ;; *) printf ''; return 0 ;; esac
  printf '%s' "${p%% *}"
}

# _ghs_pr_json <OPEN|MERGED|CLOSED> <sha> <branch> <title> <base> <mergedAt>
_ghs_pr_json() {
  jq -nc --arg s "$1" --arg sha "$2" --arg br "$3" --arg ti "$4" --arg ba "$5" --arg at "$6" \
    '{state:(if $s=="OPEN" then "open" else "closed" end),
      merged_at:(if $s=="MERGED" then (if $at=="" then "2026-01-01T00:00:00Z" else $at end) else null end),
      head:{sha:$sha,ref:$br},base:{ref:$ba},title:$ti}'
}

gh_rest_stub() {
  local T="${GHT:?gh_rest_stub: GHT (the fixture dir) must be set}"
  local all="$*" a n ref row st sha brn ti base
  # BH-7906: the scale knobs (tests/lib/scale.sh). Unset = this block is skipped.
  if [ -n "${SCALE_FAKE_LATENCY_MS:-}${SCALE_FAKE_RATE_LIMIT_EVERY:-}" ]; then
    . "$(dirname "${BASH_SOURCE[0]}")/scale.sh" || return 1
    scale_fake_gate github "$T" && return 0
  fi
  case "$all" in
    *"-X PATCH"*"/pulls/"*|*"-X PATCH"*"/issues/"*)
      printf '%s\n' "$all" >> "$T/closed.txt"
      st=$(_ghs_st patch 200)
      _ghs_send "$st" '{"state":"closed"}'; return 0 ;;
    *"-X POST"*"/comments"*)
      printf '%s\n' "$all" >> "$T/comments.txt"
      for a in "$@"; do
        case "$a" in body=@*) cat "${a#body=@}" >> "$T/comment-bodies.txt" 2>/dev/null ;; esac
      done
      _ghs_send "$(_ghs_st comment 201)" '{"id":1}'; return 0 ;;
    *"-X POST"*"rerun-failed-jobs"*)
      printf '%s\n' "$all" >> "$T/reruns.txt"
      _ghs_send "$(_ghs_st rerun 201)" '{}'; return 0 ;;
    *"vnd.github.v3.diff"*)
      # NEVER an empty 2xx body: gh_rest reads that as UNVERIFIABLE, so a fixture
      # with no diff of its own would silently become "the diff could not be
      # read" — the row that must only happen when a suite asks for it ($T/st-diff).
      if [ -s "$T/prdiff" ]; then _ghs_send "$(_ghs_st diff 200)" "$(cat "$T/prdiff")"
      else _ghs_send "$(_ghs_st diff 200)" "$(printf -- '+++ b/src/x.ts\n+const a = 1;\n')"; fi
      return 0 ;;
    *"-X GET"*"/issues/"*"/comments"*)
      # A TICKET'S THREAD, for the hold reads (BH-2504, bin/lib/hold-push.sh
      # hold_read): $T/comments-<n>.json when the suite wrote one, and the
      # outage the suites already spell GH_ISSUE_FAIL=1 (or $T/issue-fail).
      n=$(_ghs_prnum "$all")
      if [ "${GH_ISSUE_FAIL:-}" = 1 ] || [ -f "$T/issue-fail" ]; then
        _ghs_send 403 '{"message":"API rate limit already exceeded (stub)"}'; return 0
      fi
      if [ -f "$T/comments-$n.json" ]; then
        _ghs_send "$(_ghs_st comments 200)" "$(cat "$T/comments-$n.json")"; return 0
      fi
      if [ -s "$T/prcomments.json" ]; then
        _ghs_send "$(_ghs_st comments 200)" "$(cat "$T/prcomments.json")"
      elif [ -s "$T/prcomments" ]; then
        # Posted by the hub App, as the head-bound re-review is: since BH-1992
        # br_findings reads only a verdict author's comment as a brief.
        _ghs_send "$(_ghs_st comments 200)" "$(jq -nc --arg b "$(cat "$T/prcomments")" '[{user:{login:"cromford[bot]"}, body:$b}]')"
      else
        _ghs_send "$(_ghs_st comments 200)" '[]'
      fi
      return 0 ;;
    *"-X GET"*"/issues/"*)
      # THE TICKET ITSELF (BH-2504): every lane that pushes a PR branch reads
      # its issue first. $T/issue-<n>.json when the suite wrote one; otherwise
      # an open, ai-build-labelled FIXTURE issue — a ticket nobody held, which
      # is what every suite written before the hold read already assumed.
      ref=$(_ghs_ref "$all")
      if [[ "$ref" =~ /issues/[0-9]+(\?|$) ]]; then
        n=$(_ghs_prnum "$all")
        if [ "${GH_ISSUE_FAIL:-}" = 1 ] || [ -f "$T/issue-fail" ]; then
          _ghs_send 403 '{"message":"API rate limit already exceeded (stub)"}'; return 0
        fi
        if [ -f "$T/issue-$n.json" ]; then _ghs_send 200 "$(cat "$T/issue-$n.json")"
        else _ghs_send 200 "$(jq -nc --argjson n "${n:-0}" '{number:$n,state:"open",title:"FIXTURE ticket",body:"",labels:[{name:"ai-build"}]}')"; fi
        return 0
      fi
      ;;
    *"-X GET"*"search/issues"*)
      _ghs_send "$(_ghs_st search 200)" \
        "$(cut -f1 "$T/mergedprs" 2>/dev/null | jq -R . | jq -sc '{items:[.[]|select(length>0)|{html_url:.}]}')"
      return 0 ;;
    # THE OPEN-PR LIST (`repos/<slug>/pulls?...`, never `/pulls/<n>`).
    # harness_pr_list paged it with a bare `gh api` until BH-782 put it behind
    # gh_rest, so it arrives HERE now and no longer at the suites' own
    # `/pulls?state=` arm — and an unanswered list is rc 75, which reads to
    # every caller as "the list is unavailable". br_contested_hold is the one
    # that shows it: an unreadable competitor list writes no hold at all, so a
    # stub that stayed silent turned the whole contested-hold family into
    # "rebuilt as before". The fixture is the raw REST array the suites already
    # write; no fixture falls through to the unknown-route answer below.
    *"-X GET"*"/pulls?"*)
      if [ -s "$T/openprs" ]; then
        _ghs_send "$(_ghs_st prlist 200)" "$(cat "$T/openprs")"
        return 0
      fi
      ;;
    # A PR's REVIEWS list (BH-2200: bin/blocked-resolver.sh reads it over REST
    # for the lead's CHANGES_REQUESTED on every park). ABOVE the PR-object arm,
    # which would otherwise answer an object where GitHub answers an array.
    # $T/reviews-<n>.json (the resolver-review-consumer suite's per-PR fixture),
    # else $T/prreviews.json, else []. $T/st-reviews sets the status and a
    # $T/reviews-fail marker answers 403; every read is logged to
    # $T/revreads.txt, so "no reviews were read" stays a fact about calls.
    *"-X GET"*"/pulls/"*"/reviews"*)
      printf '%s\n' "$all" >> "$T/revreads.txt"
      st=$(_ghs_st reviews 200); [ -f "$T/reviews-fail" ] && st=403
      case "$st" in 2*) ;; *) _ghs_send "$st" '{"message":"API rate limit exceeded (stub)"}'; return 0 ;; esac
      n=$(_ghs_prnum "$all")
      if [ -f "$T/reviews-$n.json" ]; then _ghs_send "$st" "$(cat "$T/reviews-$n.json")"
      elif [ -f "$T/prreviews.json" ]; then _ghs_send "$st" "$(cat "$T/prreviews.json")"
      else _ghs_send "$st" '[]'; fi
      return 0 ;;
    *"-X GET"*"/pulls/"*)
      st=$(_ghs_st pr 200)
      case "$st" in 2*) ;; *) _ghs_send "$st" '{}'; return 0 ;; esac
      n=$(_ghs_prnum "$all")
      # A hit the merged-PR search handed back is answered from that row, so the
      # whole-key re-check the lane makes sees the branch and title it filters on.
      row=$(awk -F'\t' -v n="$n" '$1 ~ ("/pull/" n "$") {print; exit}' "$T/mergedprs" 2>/dev/null)
      if [ -n "$row" ]; then
        _ghs_send "$st" "$(_ghs_pr_json MERGED "$(_ghs_f prhead)" \
          "$(printf '%s' "$row" | cut -f3)" "$(printf '%s' "$row" | cut -f4)" main \
          "$(printf '%s' "$row" | cut -f2)")"
        return 0
      fi
      # A PR THIS RUN ALREADY CLOSED reads closed, and the memory of that is
      # $T/closed.txt itself — the record every suite truncates in its own reset,
      # so a section that starts again starts with an open PR and no stub state
      # outlives the scenario that made it.
      ref=$(_ghs_ref "$all")
      if [ -n "$ref" ] && [ ! -f "$T/patch-noflip" ] \
         && grep -qF -- "-X PATCH $ref " "$T/closed.txt" 2>/dev/null; then
        _ghs_send "$st" "$(_ghs_pr_json CLOSED "$(_ghs_f prhead)" "$(_ghs_f prbranch)" \
          "$(_ghs_f prtitle)" "$(cat "$T/prbase" 2>/dev/null || echo main)" "")"
        return 0
      fi
      # The suites' own convention, and its default: no $T/prstate is an OPEN PR.
      base=$(tr 'a-z' 'A-Z' < "$T/prstate" 2>/dev/null | tr -d ' \r\n')
      case "$base" in OPEN|MERGED|CLOSED) ;; *) base=OPEN ;; esac
      _ghs_send "$st" "$(_ghs_pr_json "$base" \
        "$(_ghs_f prhead)" "$(_ghs_f prbranch)" "$(_ghs_f prtitle)" \
        "$(cat "$T/prbase" 2>/dev/null || echo main)" "")"
      return 0 ;;
  esac
  # An `-i` route this stub does not know: a 200 with an empty body, which the
  # gh-rest contract reads as UNVERIFIABLE rather than as a state.
  _ghs_send 200 ''
  return 0
}
