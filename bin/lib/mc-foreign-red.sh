#!/bin/bash
# bin/lib/mc-foreign-red.sh — A PR EJECTED FROM A RED MERGIFY BATCH IT DID NOT
# BREAK GOES BACK IN, ONCE (BH-3776). Sourced by bin/merge-conductor.sh, never
# executed.
#
# THE CASE (#3759, 14h+). Mergify ejected a green, approved head when its batch
# draft #3767 went red on tests/fleet-propagate-test.sh, which the PR never
# touched; #3768 on the same main passed it. BH-636's re-entry arm never put it
# back: after a real ejection Mergify leaves its OWN check runs on the head
# (`Rule: … (queue)` failure, `Mergify Merge Queue` neutral "Dequeued — checks
# failed"), GitHub reports the PR UNSTABLE, and the arm tested the raw merge
# state for CLEAN. Every real ejection sat on `push a fix` for good.
#
# THE RULE (fr_reentry_gate, called from the arm in place of that raw test).
#   1. UNSTABLE counts as CLEAN for re-entry only when every check run NOT from
#      the mergify app is completed success|neutral|skipped, a Mergify check is
#      what is non-green, and every commit status is success. Anything else,
#      a failed read or a page that does not hold every run included, is not.
#   2. The batch failure is attributed before anything is re-queued: the newest
#      dequeued Mergify comment bound to THIS head names the draft and the
#      failing runs, the run logs name the suites (flaky_run_tests_strict), and
#      each name is checked against the PR's files (mc_pr_files) and, for the
#      harness's own repo, the test-impact map (an `always` suite is never
#      untouched; a `full` row, or a diff the map says makes CI run the whole
#      corpus, ties EVERY failing suite to the PR). A later green batch of the same
#      workflow on the same main base is flake evidence, and it can only lift
#      `unknown`: that batch does not contain this PR, so it passes whether or
#      not this PR broke the suite and says nothing against `own`. It lifts
#      only an unknown whose every name was checked against the PR and found
#      untouched: a `job:` name (the job failed, the log named no test) cannot
#      be checked, so a verdict holding one is never lifted (the operator, 16:02Z).
#      For the harness's own repo a later batch counts for a run only when
#      its CI-plan job log proves it ran every suite that run failed
#      (_fr_batch_ran, BH-3857): batches are tiered, so a green one may have
#      quarantined the suite, skipped its guard, or left it to the nightly.
#        own         a failing name equals a PR file or a map tie, or the
#                    diff ran the corpus (infra / unknown reach). Always;
#                    nothing upgrades it
#        foreign     nothing touches the PR, and every name is an untouched
#                    path, or (no job: name) a later batch passed every
#                    failing workflow
#        unknown     nothing to attribute (no comment for this head, no run,
#                    non-path names with no later pass, or ANY job: name,
#                    later pass or not)
#        nomap       (cromford only) the test-impact map cannot be built
#                    where the conductor runs: no checkout on main with a
#                    tests/ dir (MC_TI_ROOT, then harness-sync's checkout at
#                    <harness>/../harness-checkout, BH-3857), and MC_H has no
#                    tests/: no attribution at all, BH-636 exactly (raw CLEAN
#                    only)
#        unreadable  an HTTP read failed, the test-impact select failed or
#                    printed no reason line, a failing check is not an Actions
#                    run (no /actions/runs/ link: Vercel, a commit status), or
#                    ANY failing run's path, base or head could not be read or
#                    its log could not be read in full (failed, empty, over
#                    FLAKY_LOG_MAX, more than FLAKY_TESTS_MAX names, a failed
#                    job that names nothing next to one that does). Fail
#                    closed: one run or check that cannot be attributed is
#                    never outvoted by the others
#   3. raw CLEAN re-queues as BH-636 always did on `foreign` and `unknown`;
#      Mergify-only UNSTABLE re-queues only on `foreign`. `own` never
#      re-queues, and `unreadable` never does either (raw CLEAN included): it
#      waits a tick with its own reason.
#
# Once per (PR, head): the requeue (BH-636's `requeued` mark), the PR comment
# (`fqattr`, written BEFORE the post), the own/unknown log line (`fqlog`; in
# observe mode a marker file under foreign-red/, since observe marks nothing).
# A definitive verdict is cached per (PR, head) under foreign-red/ so a
# deferred row costs no second set of reads. `unknown` is cached with the
# dequeue comment it was read from (id@updated_at) AND the runs it was judged
# on (path, base, created_at), the sentence prefix and the ledger-eligible
# rows: on the same comment the next tick reads the comments and the one
# later-batch list, never the runs, logs or files, and turns `foreign` when a
# later batch passed (Mergify does not edit the comment when that happens).
# `unreadable` is cached with the dequeue comment key it was read under, and
# trusted for MC_FR_UNREADABLE_TTL_MINS only (file mtime; 0 = never cached);
# fr_reentry_gate reads the cache BEFORE the Mergify-only check-runs read, so a
# cached verdict costs no GitHub read at all (BH-3857). A later batch's parsed
# plan is cached per run id (plan_<id>). Losing the cache costs reads, never
# writes.
# Only an untouched, path-shaped, non-always name from a selected (not corpus)
# diff is ever written to ci_flakes; anything matching the PR's files or map
# ties, and anything in a corpus run, is `own` first.
#
# No root of its own: paths come from MC_STATE_DIR / MC_H, which the conductor
# lib sets. Every decision read goes through gh_rest / mc_rest_var; the log read
# is flaky_run_tests_strict (bin/lib/flaky.sh), and the CI-plan job's log goes
# through gh_ci_api (bin/lib/gh-ci-read.sh, which flaky.sh sources): a box PAT
# that 403s on Actions gets one read-only App retry instead of a silent rc 2.

# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/deployment.sh}" || return 1
FR_PAYLOAD_RE='-\*- Mergify Payload -\*-(?<p>[\s\S]*?)-\*- Mergify Payload End -\*-'
FR_WHY=""; FR_LINE=""; FR_VERDICT=""; FR_FLAKES=""; FR_CKEY=""
# The job in .github/workflows/harness-ci.yml that runs bin/ci-plan.sh; its log
# is what _fr_batch_ran reads (the suite pins the name against the workflow).
FR_PLAN_JOB="CI plan (what this run tests)"

# _fr_knob <ENV> <default> — a merge-conductor lane knob for this project (the
#   conductor's loop variable P), a non-negative integer, else the default.
_fr_knob() {
  local v
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor "$1" "${P:-}" 2>/dev/null)
  else v="${!1:-}"; fi
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  printf '%s' "$v"
}

# _fr_ti_root — where the harness repo's test-impact map is built (BH-3857).
#   The first checkout ON main with an executable bin/test-impact.sh and a
#   tests/ dir: MC_TI_ROOT, then harness-sync's own checkout beside the harness
#   (<harness>/../harness-checkout; every sync pulls it ff-only, so no fetch is
#   spent here). Local git only. Else MC_H, today's root, which on the hub has
#   no tests/ and so answers nomap. rc 1 when not even MC_H has the script.
_fr_ti_root() {
  local c
  for c in "${MC_TI_ROOT:-}" "${MC_H:+${MC_H%/*}/harness-checkout}"; do
    [ -n "$c" ] && [ -x "$c/bin/test-impact.sh" ] && [ -d "$c/tests" ] || continue
    [ "$(git -C "$c" symbolic-ref --short HEAD 2>/dev/null)" = main ] || continue
    printf '%s\n' "$c"; return 0
  done
  [ -n "${MC_H:-}" ] && [ -x "$MC_H/bin/test-impact.sh" ] || return 1
  printf '%s\n' "$MC_H"
}

# fr_mergify_only_unstable <owner/repo> <head>
#   rc 0 the only non-green checks on the head are Mergify's own bookkeeping
#   rc 1 not (a real check or status is not green, or nothing of Mergify's is)
#   rc 2 a read failed or did not hold every row
fr_mergify_only_unstable() {
  local slug="$1" head="$2" cr st v
  [ -n "$slug" ] && [ -n "$head" ] || return 2
  mc_rest_var cr gh_rest GET "repos/$slug/commits/$head/check-runs" -F per_page=100 || return 2
  v=$(jq -r '
    def green: .status == "completed" and ((.conclusion // "") | IN("success","neutral","skipped"));
    (.check_runs // null) as $r
    | if ($r | type) != "array" then "bad"
      elif (.total_count // 0) > ($r | length) then "partial"
      elif any($r[]; (.app.slug // "") != "mergify" and (green | not)) then "red"
      elif any($r[]; (.app.slug // "") == "mergify"
                     and ((.status != "completed") or ((.conclusion // "") | IN("success","skipped") | not))) then "mergify"
      else "none" end' <<<"$cr" 2>/dev/null) || return 2
  case "$v" in mergify) ;; bad|partial) return 2 ;; *) return 1 ;; esac
  mc_rest_var st gh_rest GET "repos/$slug/commits/$head/status" -F per_page=100 || return 2
  # The combined `state` is `pending` when there are no statuses at all, so the
  # list is judged, not the summary. An empty list passes.
  v=$(jq -r '(.statuses // null) as $s
    | if ($s | type) != "array" then "bad"
      elif (.total_count // ($s | length)) > ($s | length) then "bad"
      elif all($s[]; .state == "success") then "ok" else "red" end' <<<"$st" 2>/dev/null) || return 2
  case "$v" in ok) return 0 ;; red) return 1 ;; *) return 2 ;; esac
}

# fr_dequeue_batch <owner/repo> <num> <head>
#   -> "<draft# or ->\t<run ids, space-separated, or ->\t<comment id>@<updated_at>"
#   rc 0 the newest dequeued Mergify comment names this head (ids may be `-`)
#   rc 1 no dequeued comment, or the newest one is about another head
#   rc 2 the comments could not be read, or the comment for this head lists a
#        failing check this lib cannot read: every `- ` bullet under
#        "Failing checks:" must link an Actions run (Mergify's shape:
#        ``- ❌ [`<check>`](…/actions/runs/<id>/job/<j>) ([job log](…))``); a
#        Vercel build or a commit status has none, and dropping it would let
#        the Actions runs alone clear the batch (#3798 round 3, N3). A list
#        with no bullet at all is the same: nothing to attribute it to.
#   The comment is picked by (created_at, id), never updated_at: Mergify edits
#   older status comments after newer ones exist (BH-3480).
fr_dequeue_batch() {
  local slug="$1" num="$2" head="$3" raw line d s ids k chk
  mc_rest_var raw gh_rest_issue_comments "$slug" "$num" 1000 || return 2
  line=$(jq -r --arg re "$FR_PAYLOAD_RE" '
    [ .[] | select(type == "object" and (.user.login // "") == "mergify[bot]"
                   and ((.body // "") | type == "string") and ((.body // "") | test($re)))
          | select(((.body | capture($re).p | fromjson? | .state) // "") == "dequeued") ]
    | sort_by([(.created_at // ""), (.id // 0)]) | last
    | if . == null then "NONE" else
        .body as $b
        | (([$b | scan("on draft #([0-9]+)")] | last // [""]) | .[0]) as $d
        | ([$b | scan("Left the queue\\*\\*[^\\n]*? at `([0-9a-fA-F]{7,40})`")] | last // [""] | .[0]) as $s
        | ($b | split("Failing checks:") | if length > 1 then (.[1] | split("\n## ") | .[0]) else "" end) as $fc
        | ([$fc | scan("/actions/runs/([0-9]+)") | .[0]] | unique | join(" ")) as $ids
        | ([$fc | split("\n")[] | select(test("^[[:space:]]*[-*] "))]) as $bul
        | (if ($b | contains("Failing checks:")) | not then "ok"
           elif ($bul | length) == 0 then "bad"
           elif any($bul[]; test("/actions/runs/[0-9]+") | not) then "bad"
           else "ok" end) as $chk
        | ((.id // "" | tostring) + "@" + (.updated_at // "")) as $k
        | [$d, $s, $ids, $k, $chk] | map(if . == "" then "-" else . end) | @tsv end' <<<"$raw" 2>/dev/null) || return 2
  [ "$line" = NONE ] && return 1
  # Empty fields go out as `-`: a tab is whitespace to `read`, so two in a row
  # would collapse and shift every later field left.
  # The caller reads this output with the same `read`, so it keeps the `-`s.
  IFS=$'\t' read -r d s ids k chk <<<"$line"
  [ "${#s}" -ge 7 ] || return 1
  case "$head" in "$s"*) ;; *) return 1 ;; esac
  [ "$chk" = ok ] || return 2
  printf '%s\t%s\t%s\n' "${d:--}" "${ids:--}" "${k:--}"
}

# _fr_base_of <display_title> — the short main sha Mergify puts in a draft's
#   title (`merge queue: checking #31 on main (474d69b)`), lower-cased.
_fr_base_of() { sed -nE 's/.* on [^ ]+ \(([0-9a-fA-F]{7,40})\).*/\1/p' <<<"$1" | tr 'A-F' 'a-f'; }
# _fr_same_base <a> <b> — equal on their common prefix of at least 7 chars.
_fr_same_base() {
  local a="$1" b="$2" n
  [ "${#a}" -ge 7 ] && [ "${#b}" -ge 7 ] || return 1
  n=${#a}; [ "${#b}" -lt "$n" ] && n=${#b}
  [ "${a:0:$n}" = "${b:0:$n}" ]
}
# _fr_impact_scope <reason-file> — what test-impact's reason line says CI ran
#   for this diff. `select` prints `impact: <n> of <m> suites (<reason>)` on fd 3,
#   which its dispatcher (ti_emit) routes to stderr; the caller captures both.
#   -> corpus    `map-only: CI runs the corpus, full: …` (an infra or
#                unknown-reach path: --map-only lists only the map's picks,
#                but CI ran every suite) or any `full: …` reason
#   -> nomap     the map could not be built HERE: the reason line is exactly
#                `impact: <n> of <m> suites (full: the map could not be built)`
#                or `impact: 0 of 0 suites (…)` — the root has no tests/ (the
#                hub's MC_H: harness-sync never ships tests/). Not a corpus
#                diff and not the PR's own; this environment cannot attribute
#                at all (F2). Read from the reason line ALONE, anchored: a PR
#                path that holds the phrase never switches attribution off.
#   -> selected  anything else
#   rc 2 no reason line: whether CI ran the corpus is unknown.
_fr_impact_scope() {
  local r line
  line=$(grep -E '^impact: [0-9]+ of [0-9]+ suites \(.*\)$' "$1" 2>/dev/null | tail -n 1)
  r=$(sed -nE 's/^impact: [0-9]+ of [0-9]+ suites \((.*)\)$/\1/p' <<<"$line")
  case "$line" in
    'impact: 0 of 0 suites ('*) echo nomap; return 0 ;;
  esac
  case "$r" in
    '') return 2 ;;
    'full: the map could not be built') echo nomap ;;
    "map-only: CI runs the corpus"*|full:*) echo corpus ;;
    *) echo selected ;;
  esac
}
_fr_cache_file() { printf '%s/foreign-red/%s_%s_%s' "${MC_STATE_DIR:-}" "${1//\//_}" "$2" "$3"; }
# _fr_cache_put <file> <verdict> <line 2> <lines 3+> — best effort; prunes >3d.
_fr_cache_put() {
  mkdir -p "${1%/*}" 2>/dev/null \
    && find "${1%/*}" -maxdepth 1 -type f -mtime +3 -delete 2>/dev/null
  printf '%s\n%s\n%s\n' "$2" "$3" "$4" > "$1" 2>/dev/null || true
}

# _fr_batch_ran <owner/repo> <run id> <suites, one per line> (BH-3857) — did
#   that later merge-queue batch of the harness repo RUN every one of them?
#   Batches are tiered (bin/ci-plan.sh, bin/test-tiers.sh), so a green one may
#   not have. Its CI-plan job log ($FR_PLAN_JOB) answers, read raw like
#   flaky_run_tests_strict's log and capped at FLAKY_LOG_MAX:
#     - the summary `impact: N of M suites (…) — K shard(s), mode=full` must
#       be there, mode=full (a merge-queue batch); else not ran
#     - `##[warning]ci-plan: the tier step failed, so this batch runs every
#       suite…` at line start: every suite ran
#     - else S did not run when the log says `tiers: quarantine S — out of the
#       batch` or `tiers: guard S skipped — …`, or the checkout's
#       catalog/test-tiers.tsv puts S in the nightly tier (no tier file: not
#       ran). Every match is anchored at line start, after the timestamp, so a
#       changed path quoted inside another line never reads as one.
#   The parse is cached per run id (plan_<id>; a completed run never changes).
#   rc 0 ran all; rc 1 not; rc 2 a read failed. The caller counts 1 and 2 alike.
_fr_batch_ran() {
  local slug="$1" id="$2" suites="$3" pf plan="" jraw jid tmp sz max="${FLAKY_LOG_MAX:-0}" root tiers s
  [ -n "${MC_STATE_DIR:-}" ] && [ -n "$id" ] && [ -n "$suites" ] || return 2
  pf="$MC_STATE_DIR/foreign-red/plan_$id"
  [ -s "$pf" ] && plan=$(cat "$pf" 2>/dev/null)
  if [ -z "$plan" ]; then
    case "$max" in ''|*[!0-9]*|0) return 2 ;; esac
    mc_rest_var jraw gh_rest GET "repos/$slug/actions/runs/$id/jobs" -F per_page=100 || return 2
    jid=$(jq -r --arg n "$FR_PLAN_JOB" '[.jobs[]? | select(.name == $n) | .id | tostring]
      | if length == 1 then .[0] else "" end' <<<"$jraw" 2>/dev/null) || return 2
    case "$jid" in ''|*[!0-9]*) return 2 ;; esac
    tmp=$(mktemp "${TMPDIR:-/tmp}/fr-plan.XXXXXX") || return 2
    if ! GH_CI_READ_WHAT="actions/jobs/<id>/logs" gh_ci_api "$slug" "repos/$slug/actions/jobs/$jid/logs" --allow-escape-sequences > "$tmp" 2>/dev/null; then rm -f "$tmp"; return 2; fi
    sz=$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')
    case "$sz" in ''|*[!0-9]*|0) rm -f "$tmp"; return 2 ;; esac
    [ "$sz" -le "$max" ] || { rm -f "$tmp"; return 2; }
    # M<TAB><mode> from the last summary, A when the tier step failed, D<TAB><suite>
    # per suite the tier step dropped.
    plan=$(sed -E $'s/\r$//; s/\033\\[[0-9;]*[A-Za-z]//g; s/^\xef\xbb\xbf//; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//' "$tmp" | awk '
      /^impact: [0-9]+ of [0-9]+ suites \(.*\) — [0-9]+ shard\(s\), mode=[a-z-]+$/ { m = $0; sub(/.*, mode=/, "", m) }
      /^(##\[warning\]|::warning::)ci-plan: the tier step failed, so this batch runs every suite/ { a = 1 }
      /^tiers: quarantine tests\/[^ ]+\.sh — out of the batch/ { print "D\t" $3 }
      /^tiers: guard tests\/[^ ]+\.sh skipped — / { print "D\t" $3 }
      END { print "M\t" m; if (a) print "A" }')
    rm -f "$tmp"
    [ -n "$plan" ] || return 2
    mkdir -p "${pf%/*}" 2>/dev/null && printf '%s\n' "$plan" > "$pf" 2>/dev/null
  fi
  [ "$(awk -F'\t' '$1 == "M" { print $2 }' <<<"$plan")" = full ] || return 1
  grep -qx A <<<"$plan" && return 0
  root=$(_fr_ti_root) || return 1
  tiers="$root/catalog/test-tiers.tsv"
  [ -r "$tiers" ] || return 1
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    grep -qxF -- "D"$'\t'"$s" <<<"$plan" && return 1
    awk -F'\t' -v s="$s" '$1 == s && $2 == "nightly" { f = 1 } END { exit !f }' "$tiers" && return 1
  done <<<"$suites"
  return 0
}

# _fr_later <owner/repo> — reads the merge-queue runs once and sets the
#   caller's later_ok (1 when EVERY failing run has a later green batch of the
#   same workflow on the same main base) and later_draft (the first one named).
#   It reads the caller's paths/bases/created/suites arrays through bash's
#   dynamic scope (3.2 has no namerefs). For the harness's own repo a later
#   batch counts only when _fr_batch_ran proves it ran that run's suites, and
#   at most MC_FR_LATER_PROBES same-base batches are probed per run (BH-3857).
#   rc 2 the read failed.
_fr_later() {
  local slug="$1" n lp lid lnum lb lruns own=0 probes k
  later_ok=1; later_draft=""
  [ "$slug" = "$HARNESS_REPO" ] && own=1
  probes=$(_fr_knob MC_FR_LATER_PROBES 3); [ "$probes" -ge 1 ] 2>/dev/null || probes=3
  mc_rest_var lruns gh_rest GET "repos/$slug/actions/runs?event=pull_request&per_page=100" || return 2
  for n in "${!paths[@]}"; do
    lp=""; k=0
    while IFS=$'\t' read -r lid lnum lb; do
      _fr_same_base "${bases[$n]}" "$lb" || continue
      if [ "$own" = 1 ]; then
        k=$((k + 1)); [ "$k" -le "$probes" ] || break
        _fr_batch_ran "$slug" "$lid" "${suites[$n]:-}" </dev/null || continue
      fi
      lp="$lnum"; [ "$lp" != - ] || lp="run $lid"
      break
    done < <(jq -r --arg p "${paths[$n]}" --arg c "${created[$n]}" '
      [ .workflow_runs[]? | select((.head_branch // "" | startswith("mergify/merge-queue/")) and .path == $p
          and .status == "completed" and .conclusion == "success" and (.created_at // "") > $c) ]
      | sort_by(.created_at) | .[]
      | [(.id | tostring), ((.pull_requests[0].number // "") | tostring | if . == "" then "-" else "#" + . end),
         ((.display_title // "") | capture(" on [^ ]+ \\((?<b>[0-9a-fA-F]{7,40})\\)").b // "" | ascii_downcase)] | @tsv' <<<"$lruns" 2>/dev/null)
    if [ -n "$lp" ]; then [ -n "$later_draft" ] || later_draft="$lp"; else later_ok=0; fi
  done
  return 0
}

# fr_attribute <owner/repo> <num> <url> <head> — sets FR_VERDICT
#   (foreign|own|unknown|unreadable), FR_SENTENCE (the PR comment, set on
#   foreign) and FR_FLAKES ("<workflow>\t<test>\t<batch head>" per ledger row).
#   An `unreadable` read under a dequeue comment is cached with that comment's
#   key for MC_FR_UNREADABLE_TTL_MINS (0 = never); one that failed before the
#   comment was read has no key and is not cached (BH-3857).
fr_attribute() {
  local ttl
  FR_CKEY=""
  _fr_attribute "$@"
  if [ "$FR_VERDICT" = unreadable ] && [ -n "$FR_CKEY" ] && [ -n "${MC_STATE_DIR:-}" ]; then
    ttl=$(_fr_knob MC_FR_UNREADABLE_TTL_MINS 15)
    [ "$ttl" -gt 0 ] && _fr_cache_put "$(_fr_cache_file "$1" "$2" "$4")" unreadable "$FR_CKEY" ""
  fi
  return 0
}

# _fr_cached <owner/repo> <num> <head> — the cached verdict the gate may act on
#   without a read: own or foreign, or unreadable inside the TTL (file mtime).
#   Sets FR_VERDICT/FR_SENTENCE/FR_FLAKES; rc 1 nothing usable (unknown is
#   fr_attribute's to re-judge).
_fr_cached() {
  local cf v ttl
  [ -n "${MC_STATE_DIR:-}" ] || return 1
  cf=$(_fr_cache_file "$1" "$2" "$3")
  [ -s "$cf" ] || return 1
  v=$(sed -n 1p "$cf")
  case "$v" in
    own|foreign) ;;
    unreadable)
      ttl=$(_fr_knob MC_FR_UNREADABLE_TTL_MINS 15)
      [ "$ttl" -gt 0 ] && [ -n "$(find "$cf" -mmin -"$ttl" 2>/dev/null)" ] || return 1 ;;
    *) return 1 ;;
  esac
  FR_VERDICT="$v"; FR_SENTENCE=""; FR_FLAKES=""
  [ "$v" = unreadable ] && return 0
  FR_SENTENCE=$(sed -n 2p "$cf"); FR_FLAKES=$(sed -n '3,$p' "$cf")
}

# _fr_attribute — fr_attribute's body. FR_CKEY is the dequeue comment key once read.
_fr_attribute() {
  local slug="$1" num="$2" url="$3" head="$4" cf batch draft ids ckey cunk="" crec="" id run rp rc rh rb names n nm
  local files="" touched="" amb="" mapf rf scope="" rows all_paths=1 unattributable=0 any_touch=0 later_ok=0 later_draft="" prefix="" elig="" gate=""
  local shown all_names t a b c tg root
  local -a paths=() bases=() created=() bheads=() runnames=() suites=()
  FR_VERDICT=unknown; FR_SENTENCE=""; FR_FLAKES=""
  [ -n "${MC_STATE_DIR:-}" ] || { FR_VERDICT=unreadable; return 0; }
  cf=$(_fr_cache_file "$slug" "$num" "$head")
  if [ -s "$cf" ]; then
    FR_VERDICT=$(sed -n 1p "$cf"); FR_SENTENCE=$(sed -n 2p "$cf"); FR_FLAKES=$(sed -n '3,$p' "$cf")
    case "$FR_VERDICT" in foreign|own) return 0 ;; unknown) cunk="$FR_SENTENCE"; crec="$FR_FLAKES" ;; esac
    FR_VERDICT=unknown; FR_SENTENCE=""; FR_FLAKES=""
  fi
  batch=$(fr_dequeue_batch "$slug" "$num" "$head"); case $? in
    0) ;; 1) return 0 ;; *) FR_VERDICT=unreadable; return 0 ;;
  esac
  IFS=$'\t' read -r draft ids ckey <<<"$batch"
  [ "$draft" = - ] && draft=""; [ "$ids" = - ] && ids=""; [ "$ckey" = - ] && ckey=""
  FR_CKEY="$ckey"
  # `unknown` already read from this very comment. The runs, logs and files
  # behind it have not changed, but later-batch evidence can arrive with the
  # comment untouched (Mergify never edits it when another batch passes), so
  # the cached runs are re-judged on that ONE read. `unknown` here means
  # nothing touched the PR, so a later pass is the only thing that can move it.
  # The harness repo's re-judge needs each run's suites (S rows, BH-3857): an
  # unknown cached before them is a miss, attributed again in full below.
  if [ -n "$ckey" ] && [ "$ckey" = "$cunk" ] \
     && { [ "$slug" != "$HARNESS_REPO" ] || ! grep -q '^R' <<<"$crec" || grep -q '^S' <<<"$crec"; }; then
    while IFS=$'\t' read -r t a b c; do
      case "$t" in
        R) paths+=("$a"); bases+=("$b"); created+=("$c") ;;
        S) suites[a]="${suites[a]:+${suites[a]}$'\n'}$b" ;;
        P) prefix="$a" ;;
        F) elig="${elig:+$elig$'\n'}$a"$'\t'"$b"$'\t'"$c" ;;
      esac
    done <<<"$crec"
    { [ "${#paths[@]}" -gt 0 ] && [ -n "$prefix" ]; } || return 0
    _fr_later "$slug" || { FR_VERDICT=unreadable; return 0; }
    [ "$later_ok" = 1 ] || return 0
    FR_VERDICT=foreign; FR_SENTENCE="$prefix; $later_draft on the same main passed it"; FR_FLAKES="$elig"
    _fr_cache_put "$cf" foreign "$FR_SENTENCE" "$FR_FLAKES"
    return 0
  fi
  [ -n "$ids" ] || { [ -n "$ckey" ] && _fr_cache_put "$cf" unknown "$ckey" ""; return 0; }
  command -v flaky_run_tests_strict >/dev/null 2>&1 || { FR_VERDICT=unreadable; return 0; }
  # Fail closed: every failing run must yield its path, created_at, base, head
  # and its COMPLETE list of names (flaky_run_tests_strict: a log that cannot
  # be read, is cut, or names more than the cap is rc 2, never job: names).
  # One that does not makes the whole verdict unreadable, so the runs that did
  # read can never outvote it into `foreign`.
  for id in $ids; do
    mc_rest_var run gh_rest GET "repos/$slug/actions/runs/$id" || { FR_VERDICT=unreadable; return 0; }
    rp=""; rc=""; rh=""; rb=""
    IFS=$'\t' read -r rp rc rh rb < <(jq -r '[(.head_branch // ""), (.path // ""), (.created_at // ""), (.head_sha // ""), (.display_title // "")]
      | if (.[0] | startswith("mergify/merge-queue/")) then [.[1], .[2], .[3], .[4]] | map(if . == "" then "-" else . end) | @tsv else "-" end' <<<"$run" 2>/dev/null)
    rb=$(_fr_base_of "${rb:-}")
    if [ -z "$rp" ] || [ "$rp" = - ] || [ "${rc:--}" = - ] || [ "${rh:--}" = - ] || [ -z "$rb" ]; then
      FR_VERDICT=unreadable; return 0
    fi
    names=$(flaky_run_tests_strict "$slug" "$id" 2>/dev/null) || { FR_VERDICT=unreadable; return 0; }
    [ -n "$names" ] || { FR_VERDICT=unreadable; return 0; }
    paths+=("$rp"); created+=("$rc"); bheads+=("$rh"); bases+=("$rb"); runnames+=("$names")
  done
  [ "${#paths[@]}" -gt 0 ] || { FR_VERDICT=unreadable; return 0; }
  mc_rest_var files mc_pr_files "$slug" "$num" "$url" "$head" || { FR_VERDICT=unreadable; return 0; }
  # The harness's own repo: a suite the map ties to this diff touches it. An
  # `always` suite runs for every diff, so it is never "untouched" (amb): it
  # can block the all-paths foreign and never reach the ledger. When the diff
  # made CI run the WHOLE corpus (an infra or unknown-reach path: the reason
  # line says so, or a `full` row), --map-only lists only the map's picks, yet
  # every suite in that run ran because of this diff: all of them are the PR's
  # own (#3798 round 3, N1). A map that cannot be asked, or that prints no
  # reason line, is unreadable, never "nothing touched".
  if [ "$slug" = "$HARNESS_REPO" ]; then
    root=$(_fr_ti_root) || { FR_VERDICT=unreadable; return 0; }
    mapf=$(mktemp "${TMPDIR:-/tmp}/fr-files.XXXXXX") || { FR_VERDICT=unreadable; return 0; }
    rf=$(mktemp "${TMPDIR:-/tmp}/fr-impact.XXXXXX") || { rm -f "$mapf"; FR_VERDICT=unreadable; return 0; }
    printf '%s\n' "$files" > "$mapf"
    rows=$("$root/bin/test-impact.sh" select --why --map-only --changed "$mapf" --root "$root" 2>"$rf" 3>&2) \
      || { rm -f "$mapf" "$rf"; FR_VERDICT=unreadable; return 0; }
    scope=$(_fr_impact_scope "$rf") || { rm -f "$mapf" "$rf"; FR_VERDICT=unreadable; return 0; }
    rm -f "$mapf" "$rf"
    # No map in this environment: attribute nothing, cache nothing; the gate
    # falls back to BH-636 exactly (fr_reentry_gate, `nomap`).
    [ "$scope" = nomap ] && { FR_VERDICT=nomap; return 0; }
    awk -F'\t' '$2 == "full"' <<<"$rows" | grep -q . && scope=corpus
    if [ "$scope" = corpus ]; then
      FR_VERDICT=own; _fr_cache_put "$cf" own "" ""; return 0
    fi
    touched=$(awk -F'\t' '$2 != "always" && $1 != "" { print $1 }' <<<"$rows" | sort -u)
    amb=$(awk -F'\t' '$2 == "always" && $1 != "" { print $1 }' <<<"$rows" | sort -u)
  fi
  # A name is the PR's own on ANY exact match with its files or the map's ties,
  # whatever its tag. Only then does PROVENANCE matter (flaky_run_tests_strict
  # tags each name; #3798 round 5): P is a file the runner reported (a harness
  # `--- tests/<x>.sh` line, a jest/vitest `FAIL <file>` token). T (a runner
  # title, however path-like: `works`, `api/health`) and J (a job: name)
  # name no file, so whether the PR touches them cannot be checked:
  # unattributable, never an untouched path, never lifted, never ledgered.
  for n in "${!paths[@]}"; do
    while IFS=$'\t' read -r tg nm; do
      [ -n "$nm" ] || continue
      if grep -qxF -- "$nm" <<<"$files" || grep -qxF -- "$nm" <<<"$touched"; then any_touch=1; continue; fi
      [ "$tg" = P ] || { all_paths=0; unattributable=1; continue; }
      if grep -qxF -- "$nm" <<<"$amb"; then all_paths=0; continue; fi
      # An untouched path: the only kind of name the ledger may ever see.
      elig="${elig:+$elig$'\n'}${paths[$n]}"$'\t'"$nm"$'\t'"${bheads[$n]}"
    done <<<"${runnames[$n]}"
  done
  # `own` first and final: a later batch never contained this PR, so its pass
  # cannot clear a suite the PR touches.
  if [ "$any_touch" = 1 ]; then
    FR_VERDICT=own; _fr_cache_put "$cf" own "" ""; return 0
  fi
  # A `job:` name says which job failed, not which test, and a runner title
  # names a test, not a file: whether the PR touches either cannot be checked,
  # and later-batch evidence may lift unknown only when the PR touches NONE of
  # the failing tests (the operator, 16:02Z). Any such name pins the verdict at
  # unknown: no later-batch read is spent on it.
  # What a later batch must have run for run n: every name it failed (all
  # checked and untouched by now; _fr_batch_ran, harness repo only).
  for n in "${!paths[@]}"; do suites[n]=$(cut -f2- <<<"${runnames[$n]}" | sed '/^$/d'); done
  if [ "$unattributable" = 1 ]; then later_ok=0; later_draft=""
  else _fr_later "$slug" || { FR_VERDICT=unreadable; return 0; }; fi
  all_names=$(printf '%s\n' "${runnames[@]}" | sed '/^$/d' | cut -f2- | sed 's/^job://' | awk '!s[$0]++')
  shown=$(head -n 3 <<<"$all_names" | paste -sd, - | sed 's/,/, /g')
  [ "$(grep -c . <<<"$all_names")" -gt 3 ] && shown="$shown and $(( $(grep -c . <<<"$all_names") - 3 )) more"
  if [ -n "$draft" ]; then prefix="re-queued: batch #$draft failed $shown"
  else prefix="re-queued: the batch failed $shown"; fi
  if [ "$all_paths" != 1 ] && [ "$later_ok" != 1 ]; then
    # `unknown`, cached with the runs it was judged on so the next tick can
    # re-judge them on the later-batch read alone (G1). A verdict holding a
    # job: name or a title is cached with NO runs: nothing can ever lift it, so the next
    # tick on the same comment stops at the cache.
    FR_VERDICT=unknown
    if [ -n "$ckey" ]; then
      crec=""
      [ "$unattributable" = 1 ] || for n in "${!paths[@]}"; do
        crec="${crec:+$crec$'\n'}R"$'\t'"${paths[$n]}"$'\t'"${bases[$n]}"$'\t'"${created[$n]}"
        crec="$crec"$'\n'"$(sed "/^\$/d; s/^/S\t$n\t/" <<<"${suites[$n]}")"
      done
      crec="$crec"$'\n'"P"$'\t'"$prefix"
      [ -n "$elig" ] && crec="$crec"$'\n'"$(sed 's/^/F\t/' <<<"$elig")"
      _fr_cache_put "$cf" unknown "$ckey" "$crec"
    fi
    return 0
  fi
  FR_VERDICT=foreign; FR_SENTENCE="$prefix"
  [ "$all_paths" = 1 ] && FR_SENTENCE="$FR_SENTENCE, which this PR does not touch"
  [ "$later_ok" = 1 ] && FR_SENTENCE="$FR_SENTENCE; $later_draft on the same main passed it"
  # The ledger takes only `elig`: untouched, path-shaped, not always. A
  # name in the PR's files or the map's ties made the verdict `own` above, so
  # no filter on them is needed here (it would be unreachable by construction).
  command -v flaky_gate_set >/dev/null 2>&1 && gate=$(flaky_gate_set "$slug" 2>/dev/null)
  while IFS=$'\t' read -r a b c; do
    [ -n "$b" ] || continue
    if [ "$later_ok" = 1 ] || grep -qxF -- "$b" <<<"$gate"; then
      FR_FLAKES="${FR_FLAKES:+$FR_FLAKES$'\n'}$a"$'\t'"$b"$'\t'"$c"
    fi
  done <<<"$elig"
  _fr_cache_put "$cf" "$FR_VERDICT" "$FR_SENTENCE" "$FR_FLAKES"
  return 0
}

# _fr_log_once <word> <key> <head> <text> — one log line per (PR, head, word).
#   With merges on it is an attempt mark (`fqlog <key> <head> <word>`: the word
#   is in the mark, so an own line after an unknown one on the same head is
#   still written); in observe mode nothing may be marked,
#   so a marker file beside the verdict cache keeps the line to once instead
#   (best effort: a lost marker costs one repeated line).
_fr_log_once() {
  local mk
  if [ "${MERGES:-0}" = 1 ]; then
    mc_attempt_has "fqlog $2 $3 $1" 2>/dev/null && return 0
    mc_attempt_put "fqlog $2 $3 $1"
  elif [ -n "${MC_STATE_DIR:-}" ]; then
    mk="$MC_STATE_DIR/foreign-red/log_$(printf '%s_%s_%s' "$1" "$2" "$3" | tr -c 'A-Za-z0-9._-' '_')"
    [ -e "$mk" ] && return 0
    mkdir -p "${mk%/*}" 2>/dev/null && : > "$mk" 2>/dev/null
  fi
  mc_log "$1 $2 $3 — $4"
}

# fr_reentry_gate <owner/repo> <num> <key> <url> <head> <raw mergeState>
#   rc 0 the arm may re-queue (FR_LINE is the attribution when there is one);
#   rc 1 it may not (FR_WHY is the reason when it is not the arm's own).
fr_reentry_gate() {
  local slug="$1" num="$2" key="$3" url="$4" head="$5" ms="$6" raw
  FR_WHY=""; FR_LINE=""
  case "$ms" in
    CLEAN) raw=clean ;;
    UNSTABLE) raw=unstable ;;
    *) return 1 ;;
  esac
  # A cached verdict first (BH-3857): own, foreign, or unreadable inside its
  # TTL costs no read at all, not even the Mergify-only one. A cached foreign
  # passed that check on this very head before it was written.
  if ! _fr_cached "$slug" "$num" "$head"; then
    if [ "$raw" = unstable ]; then fr_mergify_only_unstable "$slug" "$head" || return 1; fi
    fr_attribute "$slug" "$num" "$url" "$head"
  fi
  case "$FR_VERDICT" in
    foreign) FR_LINE="$FR_SENTENCE"; return 0 ;;
    own) _fr_log_once FOREIGN_RED_OWN "$key" "$head" "its batch went red on a suite this PR touches; not re-queued"
         return 1 ;;
    nomap)
      # The test-impact map cannot be built in this environment (F2: no
      # checkout on main with tests/ (_fr_ti_root), and the hub's MC_H has none). Exactly the pre-BH-3776 arm: raw CLEAN re-queues,
      # nothing else does; no comment, no cache, no ledger. Logged once a head.
      _fr_log_once FOREIGN_RED_NOMAP "$key" "$head" "the test-impact map cannot be built here (no checkout on main with tests/ at ${MC_TI_ROOT:-${MC_H%/*}/harness-checkout}, and no tests/ under ${MC_H:-?}); BH-636 rule: re-queued only on raw CLEAN"
      [ "$raw" = clean ]; return ;;
    unreadable)
      # Never re-queued, raw CLEAN included: a batch failure nobody could read
      # is not evidence the PR is clear (the operator, #3798).
      FR_WHY="queue-ejected — the batch failure could not be read this tick; asked again next tick"
      return 1 ;;
    *) [ "$raw" = clean ] && return 0
       _fr_log_once FOREIGN_RED_UNKNOWN "$key" "$head" "the batch failure could not be pinned on anything but this PR; not re-queued"
       return 1 ;;
  esac
}

# fr_requeue_note <owner/repo> <num> <key> <head> — after a requeue was asked
#   on a foreign verdict: the mark, the PR comment, the log line, the ledger.
fr_requeue_note() {
  local slug="$1" num="$2" key="$3" head="$4" bf wf t h
  [ -n "$FR_LINE" ] || return 0
  mc_attempt_has "fqattr $key $head" 2>/dev/null && return 0
  mc_attempt_put "fqattr $key $head"
  if bf=$(mktemp "${TMPDIR:-/tmp}/fr-body.XXXXXX"); then
    printf '%s\n' "$FR_LINE" > "$bf"
    gh_rest_comment "$slug" "$num" "$bf" \
      || mc_log "$key the re-queue comment could not be posted on ${head:0:8} (HTTP ${GH_REST_STATUS:-?}); not retried"
    rm -f "$bf"
  fi
  mc_log "REQUEUE_ATTRIBUTED $key $head — $FR_LINE"
  [ -n "$FR_FLAKES" ] && command -v metric_flake >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r wf t h; do
    [ -n "$t" ] || continue
    metric_flake "$slug" "$wf" "$t" "$h" "" flake \
      || mc_log "$key the flake row for $t on ${h:0:8} could not be written; the requeue stands"
  done <<<"$FR_FLAKES"
  return 0
}
