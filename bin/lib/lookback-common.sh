#!/bin/bash
# bin/lib/lookback-common.sh — BH-1795.0: the shared contract of the weekly
# `lookback` hub lane (bin/lookback.sh). Sourced, never executed; defining the
# three functions below is its only effect.
#
# The lane reviews a week of repeat failures, clusters them and files one
# `ai-build` issue per cluster. This slice ships the driver and this contract.
# The collector, the clustering call, the two filers and the 30-day follow-up
# are defined by sibling BH-1795 slices; bin/lookback.sh calls each one only
# when `declare -F` finds it.
#
# BUNDLE — state/lookback/<YYYY-MM-DD>/bundle.json, written by
# bin/lookback-collect.sh --days <n> --out <path>:
#   {window:{from,to},
#    items:[{id, source, at, project, ticket, pr, files[], lane, reason}],
#    sources:{<name>:{ok, n, truncated, error?, detail?}},
#    incomplete:bool}
#   `at` is the ISO time of the event. A reopen item also has comment
#   ({at, author, text} or null) and comment_status (saved | no-comment |
#   unreadable | other-day | none); its pr is the ticket's PR when the hub
#   knows it. sources.reopen.detail = {pr_lookup, with_pr, with_comment}. The driver requires `.items` to be an
#   array: a missing one is a failed collection, never an empty week.
#
# CLUSTERS — state/lookback/<YYYY-MM-DD>/clusters.json, the validated output of
# lookback_cluster_run, ranked by size (item_ids length) desc, then fingerprint:
#   [{fingerprint, key_kind: file|lane|reason, key_value, item_ids[],
#     target: harness|app, project, title, cause, proposed_fix}]
#   If it exists and parses as an array the driver reuses it, so a same-day
#   re-run makes no second clustering call.
#
# LEDGER — the durable dedup store, written by the filers and the follow-up:
#   ledgers(kind=lookback_cluster, key=<fingerprint>)
#   status: filed | followed_up_recurred | followed_up_stopped
#   detail: {repo|board, issue|ticket_id, filed_at, key_kind, key_value,
#            project, target, items, item_ids[]}
#   the follow-up adds {followed_up_at, followup_new, fix_merged: yes|none|unknown,
#   fix_pr (when yes)}. The driver reads every row once per run (BH-3691): the
#   rolling-week cap counts detail.filed_at, and the summary's measure line
#   counts rows by status and fix_merged.
#
# RETURN CODES
#   lookback_file_harness|lookback_file_board <cluster_json> <run_dir>
#     print one summary line; 0 created, 3 commented, 4 not filed,
#     75 ledger outage (the driver stops ALL filing this run), other = failed.
#     Only rc 0 counts against LOOKBACK_MAX_ISSUES, which caps filings in any
#     rolling 7 days (ledger detail.filed_at), not per run.
#   lookback_cluster_run <bundle> <clusters_out>
#     0 wrote validated clusters (possibly []), 2 model output invalid,
#     75 not configured (no spend).
#   lookback_followup_run <run_dir>
#     prints summary lines; 0, or 75 deferred.
#
# KNOBS the sibling slices read (registered in catalog/lanes.d/lookback.json;
# settings key lane.lookback.<env lowercased>). The driver itself reads
# LOOKBACK_DAYS (7), LOOKBACK_MAX_ISSUES (5, per rolling 7 days), LOOKBACK_DRY
# (0 = live; 1 or any other value clusters, files nothing and warns) and
# LOOKBACK_APP_FILING (0 = app-target clusters are reported, never filed on a board).
#   LOOKBACK_MAX_USD           15   clustering call spend ceiling, dollars per run
#   LOOKBACK_CLUSTER_MIN        2   fewest items a cluster needs
#   LOOKBACK_ALERT_MIN          3   fewest occurrences of one alert family that count
#   LOOKBACK_REREVIEW_MIN       2   fewest re-reviews of one PR that count
#   LOOKBACK_FOLLOWUP_DAYS     30   days after filing before the follow-up checks
#   LOOKBACK_BUNDLE_MAX_ITEMS 400   collector item cap (past it: truncated/incomplete)
#   LOOKBACK_MODEL             ""   explicit clustering model; empty = the route decides

# lookback_fingerprint <target> <project> <key_kind> <key_value> — 16 hex chars.
# A hash of what the cluster IS, never of a title or URL, so it stays stable
# across weeks and is the ledger key.
lookback_fingerprint() {
  printf '%s|%s|%s|%s' "$1" "$2" "$3" "$4" | sha1sum | cut -c1-16
}

# lookback_reason_family <text> — the normalized reason: lowercase, URLs, shas
# (7-40 hex chars bounded by word edges) and digits removed, whitespace
# squeezed and trimmed. lookback_item_match_jq applies the same steps in jq.
lookback_reason_family() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E -e 's#https?://[^[:space:]]+##g' -e 's/\b[0-9a-f]{7,40}\b//g' -e 's/[0-9]+//g' \
             -e 's/[[:space:]]+/ /g' -e 's/^ //' -e 's/ $//'
}

# lookback_item_match_jq — prints the jq definition the cluster validator and
# the follow-up share: item_matches($kind;$value;$project) is true when a
# bundle item belongs to a cluster key, and, unless $project is cromford,
# to the same project.
lookback_item_match_jq() {
  cat <<'JQ'
def lookback_reason_family: ascii_downcase
  | gsub("https?://\\S+"; "") | gsub("\\b[0-9a-f]{7,40}\\b"; "") | gsub("[0-9]+"; "")
  | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
def item_matches($kind; $value; $project):
  (($kind == "file" and ((.files // []) | index($value)) != null)
   or ($kind == "lane" and .lane == $value)
   or ($kind == "reason" and ((.reason // "") | lookback_reason_family) == $value))
  and ($project == "cromford" or .project == $project);
JQ
}
