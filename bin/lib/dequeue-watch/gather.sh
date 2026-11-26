#!/bin/bash
# gh-identity: raw-by-design — the one raw call is `gh run view --log-failed`, and it runs inside bin/dequeue-watch.sh on the App identity that lane armed per project; a second mint here would override that choice.
# shellcheck shell=bash
# bin/lib/dequeue-watch/gather.sh — BH-3730 (BH-3719.4): the GitHub reads the
# dequeue-watch lane (bin/dequeue-watch.sh) makes before it classifies and acts.
# Sourced by the lane, never run; nothing here runs on source.
#
# The pulls/<n> read goes to the PR record first (ph_prr_read, BH-8269) and
# to GitHub only on a miss. The label lists, the Mergify payload and the
# lead-verdict status go through prr_read dequeue-watch (BH-9938; the step is
# the GH_SOURCE knob, the reads are bin/lib/prr-shadow.d/dequeue-watch.sh).
# Every other read is `gh_rest GET` except the batch log. An unread answer (rc 75,
# non-2xx) is never an empty one: a list that was not read skips the project,
# and an input attribution needs that was not read leaves it `unknown`, never
# `bystander` (D9/D11).
#
#   dqw_gather_dequeued <slug>
#     The open PR numbers carrying `merge-queue` or `dequeued`, minus any that
#     Mergify still has `queued` or `checking`. rc 1 when either list is unread.
#   dqw_gather_pr <P> <slug> <num>
#     rc 0 prints one TSV line: head url age_s attribution how mergeable stale
#     rerun_green main_red verdict head_ref run_id run_url draft checks dir.
#     <dir>/parsed is the dqw_parse_log output and <dir>/fail the FAIL lines.
#     rc 1 = skip this PR, with one log line saying why. Whenever the newest
#     payload says dequeued on the PR's current head, DQW_G_WATCH is set to
#     "<head> <age_s>" so the lane runs the watchdog whatever the skip was.
#     Ownership is per (pr, head, class) (BH-3859): the PR is skipped as
#     already-owned only when THIS run's event row was classified on an earlier
#     tick and a live action row holds that class; DQW_G_CLASS is then that
#     class, for the watchdog. A new run on the same head is gathered in full.
#   dqw_gather_resolve <P> <slug> <dequeued-nums>
#     Resolves the dqw-unowned page of every event row of the last 24 h whose PR
#     is not in this tick's dequeued list. Call it only with a list that was read.
#
# Knob: DEQUEUE_WATCH_LOG_BYTES (200000), the cap on the batch log read.
# Scratch: $DQW_TMP, the lane's per-tick directory.
# NO ROOT DEFAULT (D43): the root is $HARNESS, then $H; with neither every verb
# returns 1 and builds no path.
# gh-rest: no-graphql

_dqw_g_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_dqw_g_log() {
  local h; h=$(_dqw_g_root)
  [ -n "$h" ] || return 0
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') gather: $*" >> "$h/logs/dequeue-watch.log" 2>/dev/null || true
}

# dqw_gh_label_list <slug> <label> / dqw_gh_comment <slug> <comment-id> — the
# two GitHub reads the seam's github side makes (dqw_labels_github,
# dqw_payload_github), kept here beside the lane's other GitHub reads. Each is
# one gh_rest GET to stdout with its rc; call it as `> file`, never in $( ).
dqw_gh_label_list() { gh_rest GET "repos/$1/issues?labels=$2&state=open&per_page=100"; }
dqw_gh_comment() { gh_rest GET "repos/$1/issues/comments/$2"; }

dqw_gather_dequeued() {
  local slug="$1" f
  [ -n "$(_dqw_g_root)" ] && [ -d "${DQW_TMP:-}" ] || return 1
  f="$DQW_TMP/list-${slug//\//_}.json"
  # The record or GitHub (bin/lib/prr-shadow.d/dequeue-watch.sh): one file of
  # issue-list arrays either way. A miss in step record reads GitHub.
  prr_read dequeue-watch "$slug#labels" "$f" dqw_labels_record dqw_labels_github dqw_labels_norm "$slug" || return 1
  jq -rs 'add | map(select(.pull_request != null)
                    | select([.labels[]?.name] | (index("queued") or index("checking")) | not))
          | unique_by(.number) | .[].number' "$f"
}

dqw_gather_pr() {
  local P="$1" slug="$2" num="$3" h line state epoch cid tsv draft run left checks pr
  local head ref mergeable url age dir runs title rerun=0 log suite members m word how vline verdict="" stale=0 main_red=0 run_url
  local ev evcls own prow
  DQW_G_WATCH="" DQW_G_STALE="" DQW_G_RECORDED="" DQW_G_CLASS=""
  h=$(_dqw_g_root)
  [ -n "$h" ] && [ -d "${DQW_TMP:-}" ] || return 1
  url="https://github.com/$slug/pull/$num"
  # The payload from the record or GitHub (bin/lib/prr-shadow.d/dequeue-watch.sh):
  # one TSV line, state epoch cid draft run left checks.
  line="$DQW_TMP/payload-${slug//\//_}-$num.tsv"
  DQW_PAYLOAD_CID=""
  prr_read dequeue-watch "$slug#$num:payload" "$line" dqw_payload_record dqw_payload_github dqw_payload_norm "$slug" "$num"
  case $? in
    0) ;;
    1) _dqw_g_log "$slug#$num no Mergify payload, skipped"; return 1 ;;
    3) _dqw_g_log "$slug#$num payload comment $DQW_PAYLOAD_CID unread, skipped"; return 1 ;;
    4) _dqw_g_log "$slug#$num payload comment $DQW_PAYLOAD_CID does not parse as dequeued, skipped"; return 1 ;;
    *) _dqw_g_log "$slug#$num payload-unread, skipped"; return 1 ;;
  esac
  IFS=$'\t' read -r state epoch cid draft run left checks < "$line"
  [ "$state" = dequeued ] || { _dqw_g_log "$slug#$num payload says '$state', not dequeued"; return 1; }
  tsv=$(printf '%s\t%s\t%s\t%s' "$draft" "$run" "$left" "$checks")
  # The PR record first (bin/lib/ph-pr-record.sh). A miss logs one PRR_MISS
  # line here and runs the GitHub read below, then writes its answer back.
  # A null mergeable_state is a miss, never "-": classify reads that field.
  head=""
  if declare -F ph_prr_read >/dev/null \
     && prow=$(PH_PRR_LOG=dequeue-watch ph_prr_read "$slug" "$num" head_sha head_ref mergeable_state); then
    if head=$(jq -er '.head_sha | strings' <<<"$prow" 2>/dev/null); then
      ref=$(jq -r '.head_ref // ""' <<<"$prow")
      mergeable=$(jq -r '.mergeable_state // "-"' <<<"$prow")
    else
      head=""
      PH_PRR_LOG=dequeue-watch ph_prr_miss "$slug" "$num" no-field head_sha
    fi
  fi
  if [ -z "$head" ]; then
    gh_rest GET "repos/$slug/pulls/$num" > "$DQW_TMP/pull-${slug//\//_}-$num.json" 2>/dev/null \
      && pr=$(cat "$DQW_TMP/pull-${slug//\//_}-$num.json") \
      && head=$(printf '%s' "$pr" | jq -er '.head.sha | strings' 2>/dev/null) \
      || { _dqw_g_log "$slug#$num pull unread, skipped"; return 1; }
    ref=$(printf '%s' "$pr" | jq -r '.head.ref // ""')
    mergeable=$(printf '%s' "$pr" | jq -r '.mergeable_state // "-"')
    declare -F ph_prr_writeback >/dev/null && ph_prr_writeback "$slug" "$num" "$DQW_TMP/pull-${slug//\//_}-$num.json"
  fi
  if [ "$left" != "$head" ]; then
    _dqw_g_log "$slug#$num stale-event: left the queue at ${left:0:12}, head is now ${head:0:12}"
    DQW_G_STALE=1
    return 1
  fi
  age=$(( $(date -u +%s) - epoch ))
  DQW_G_WATCH="$head $age"
  ev=$(dqw_event_record "$slug" "$num" "$head" "$run" "$P" \
    "$(jq -nc --arg d "$draft" --arg c "$checks" --arg id "$cid" '{draft: $d, checks: $c, payload_comment_id: $id}')") \
    || { _dqw_g_log "$slug#$num ${head:0:12} event-record-failed, skipped"; return 1; }
  DQW_G_RECORDED=1
  # Ownership is per (pr, head, class). The event row is keyed (pr, head,
  # run_id), so its class says whether THIS run was classified on an earlier
  # tick; a new run on the same head has none and is gathered in full. With a
  # class, a live row of that class (bystander/flake are claimed as
  # stale-status when there is no standing verdict, as dqw_act does) owns it.
  # An observe row owns it only while the lane observes: once
  # DEQUEUE_WATCH_ACT is 1 the PR is gathered again so dqw_act takes the row
  # over. Unread list → go on, the claim in dqw_act is the dedupe of record.
  evcls=$(printf '%s' "$ev" | jq -r '.row.class // "" | strings' 2>/dev/null)
  if [ -n "$evcls" ]; then
    own=0; [ "${DEQUEUE_WATCH_ACT:-0}" = 1 ] && own=1
    if word=$(dqw_actions_list "$slug" "$num" "$head" 2>/dev/null \
              | jq -er --arg c "$evcls" --argjson act "$own" \
                  '[.rows[] | select(.status != "failed" and (.class == $c or (($c == "bystander" or $c == "flake") and .class == "stale-status"))
                               and ($act == 0 or .action != "observe")) | "\(.class)\t\(.action)"] | first // empty' 2>/dev/null); then
      DQW_G_CLASS=${word%%$'\t'*}
      _dqw_g_log "$slug#$num ${head:0:12} already-owned ($DQW_G_CLASS/${word#*$'\t'}, run $run), nothing gathered"
      return 1
    fi
  fi

  dir="$DQW_TMP/pr-$num"; mkdir -p "$dir" || return 1
  runs="$DQW_TMP/runs-${slug//\//_}.json"
  if [ ! -e "$runs" ] && [ ! -e "$runs.unread" ]; then
    gh_rest GET "repos/$slug/actions/runs?event=push&per_page=100" > "$runs.tmp" \
      && jq -e '.workflow_runs | type == "array"' "$runs.tmp" >/dev/null 2>&1 \
      && mv "$runs.tmp" "$runs" || { rm -f "$runs.tmp"; : > "$runs.unread"; }
  fi
  if [ -r "$runs" ] && [[ "$run" =~ ^[0-9]+$ ]]; then
    title=$(jq -r --argjson id "$run" '[.workflow_runs[] | select(.id == $id)][0].display_title // ""' "$runs")
    [ -n "$title" ] && jq -e --argjson id "$run" --arg t "$title" \
      'any(.workflow_runs[]; .id > $id and .display_title == $t and .status == "completed" and .conclusion == "success")' \
      "$runs" >/dev/null 2>&1 && rerun=1
  fi

  log="$dir/log"; : > "$log"; : > "$dir/parsed"; : > "$dir/fail"
  if [[ "$run" =~ ^[0-9]+$ ]]; then
    gh run view "$run" -R "$slug" --log-failed 2>/dev/null | head -c "${DEQUEUE_WATCH_LOG_BYTES:-200000}" > "$log"  # gh-guard-allow: log bytes, not a decision read; REST-backed, no GraphQL
  fi
  if dqw_parse_log "$log" > "$dir/parsed"; then
    awk -F'\t' '$1 != "-" { print $2 }' "$dir/parsed" > "$dir/fail"
  else
    : > "$dir/parsed"
    # No live suite block: the raw FAIL lines, masked as dqw_parse_log masks them.
    grep -F FAIL "$log" | sed -E 's/^[^\t]*\t[^\t]*\t//; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//' \
      | sed -E 's/(^|[^A-Za-z0-9_])(gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]{16,}/\1\2[masked]/g' \
      | cut -c1-300 | head -n "${DEQUEUE_WATCH_FAIL_LINES:-40}" > "$dir/fail"
  fi

  : > "$dir/sources"
  suite=$(awk -F'\t' '$1 != "-" { print $1; exit }' "$dir/parsed")
  if [ -n "$suite" ] && gh_rest GET "repos/$slug/contents/$suite?ref=main" | jq -er '.content | strings' 2>/dev/null \
       | base64 -d > "$dir/src" 2>/dev/null; then
    { echo "$suite"; grep -oE '(bin|tests/lib)/[A-Za-z0-9_./-]*[A-Za-z0-9_]' "$dir/src"; } | sort -u > "$dir/sources"
  fi

  members=$(dqw_batch_members "$runs" "$run" 2>/dev/null) || members=""
  for m in $num $(printf '%s\n' "$members" | grep -vx "$num" | head -7); do
    gh_rest GET "repos/$slug/pulls/$m/files?per_page=100" > "$dir/pr-files-$m.json" \
      && jq -e 'type == "array"' "$dir/pr-files-$m.json" >/dev/null 2>&1 || rm -f "$dir/pr-files-$m.json"
  done
  if [ -r "$runs" ]; then
    IFS=$'\t' read -r word how <<<"$(dqw_attribute "$num" "$tsv" "$runs" "$dir/sources" "$dir")"
  else
    word=unknown; how="runs-unread"
  fi

  vline=$(vd_standing "$slug" "$num" "$head"); case $? in
    0) verdict=$(cut -f1 <<<"$vline") ;;
    1) verdict="" ;;
    *) _dqw_g_log "$slug#$num ${head:0:12} verdict-unread, skipped"; return 1 ;;
  esac
  case "$verdict" in
    MERGE|MERGE-WITH-NOTES)
      prr_read dequeue-watch "$slug#$num@${head:0:12}:status" "$dir/status" \
          dqw_status_record dqw_status_github dqw_status_norm "$slug" "$num" "$head" \
        && jq -e --arg c "$(vs_context 2>/dev/null || echo lead-verdict)" \
             '(.statuses | type == "array") and (any(.statuses[]; .context == $c and .state == "success") | not)' \
             "$dir/status" >/dev/null 2>&1 && stale=1 ;;
  esac
  main_red_flag "$P" "$slug" >/dev/null 2>&1 && main_red=1
  run_url="-"; [[ "$run" =~ ^[0-9]+$ ]] && run_url="https://github.com/$slug/actions/runs/$run"
  printf '%s\t' "$head" "$url" "$age" "$word" "$how" "$mergeable" "$stale" "$rerun" "$main_red" "${verdict:--}" \
    "${ref:--}" "$run" "$run_url" "$draft" "$checks"
  printf '%s\n' "$dir"
}

dqw_gather_resolve() {
  local P="$1" slug="$2" nums=" ${3//$'\n'/ } " h since rows pr head
  h=$(_dqw_g_root)
  [ -n "$h" ] || return 1
  since=$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
  rows=$(dqw_events_list "$slug" "" "$since" 2>/dev/null) || { _dqw_g_log "$slug events unread, no unowned page resolved"; return 0; }
  while read -r pr head; do
    [[ "$pr" =~ ^[0-9]+$ ]] && [[ "$head" =~ ^[0-9a-f]{40}$ ]] || continue
    [[ "$nums" == *" $pr "* ]] && continue
    "$h/bin/lane-alert.sh" --resolve --id "dqw-unowned:$P:$pr:${head:0:12}" dequeue-watch \
      "https://github.com/$slug/pull/$pr is no longer dequeued" >/dev/null 2>&1 || true
  done < <(printf '%s' "$rows" | jq -r '[.rows[] | "\(.pr) \(.head)"] | unique[]' 2>/dev/null)
  return 0
}
