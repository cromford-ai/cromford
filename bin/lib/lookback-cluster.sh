#!/bin/bash
# bin/lib/lookback-cluster.sh — BH-1795.2: the clustering call of the weekly
# `lookback` lane. Sourced by bin/lookback.sh, never executed; defining
# lookback_cluster_run is its only effect. The shapes and the rc convention are
# in bin/lib/lookback-common.sh, which the driver sources first.
#
# lookback_cluster_run <bundle> <clusters_out>
#   1. Model from model_routes role `lookback.cluster` (LOOKBACK_MODEL, env or
#      settings row, still wins), runner pinned from the route's rung 0 exactly
#      as bin/rule-miner.sh does. No route: rc 75, a lookback.log line (the
#      resolver already wrote the ALERTS line). A non-claude runner: one ALERTS
#      line, rc 75. No prompt file: rc 75. None of these spend.
#   2. A jq pre-pass groups the items by shared files[] path, lane and
#      lookback_reason_family, keeps groups of LOOKBACK_CLUSTER_MIN (2) or more
#      and hands them to the model as hints.
#   3. ONE agent-call, stage `lookback`, AGENT_CALL_BUDGET_USD=LOOKBACK_MAX_USD.
#      Dedup before spend: <run_dir>/cluster-call.<sha1 of .items>.done is
#      touched right after a rc 0 call, and while it exists the saved
#      cluster-run.txt is re-parsed instead of paying again. A failed call: one
#      ALERTS line, no marker, rc 1.
#   4. The answer must be a JSON array, bare or in one ```json block. Anything
#      else: one ALERTS line, `invalid: unparseable`, nothing written, rc 2.
#   5. Each proposed cluster is checked with the shared item_matches def from
#      lookback_item_match_jq, in model order. Invalid ones are dropped and
#      counted: a bad key_kind or empty field, an unknown id, an id an earlier
#      accepted cluster holds, fewer than LOOKBACK_CLUSTER_MIN distinct ids, a
#      target=app without one non-harness project, a target=harness over app
#      items on a non-harness key, or any item the key is not true of. A target
#      other than app|harness is harness, and a harness project is cromford.
#      A reason key is normalized before it is matched. Em dashes are stripped
#      from title, cause and proposed_fix.
#   6. Fingerprint via lookback_fingerprint, rank by size desc then fingerprint,
#      write clusters_out through a tmp file and mv. [] is success. Prints
#      `invalid: <n>` and logs `cluster: <v> valid, <n> invalid`; rc 0.

lookback_cluster_run() {
  local bundle="$1" out="$2"
  # The root is HARNESS, then H (BH-2613); bin/lookback.sh owns the default.
  # No root: nothing to read or log under, so no call is made (rc 75, no spend).
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 75
  local log="$h/logs/lookback.log" run_dir sop min model runner in_fp marker raw ans res rc
  run_dir=$(dirname "$out")
  mkdir -p "$run_dir" "$h/logs"
  _lbc_log() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$log"; }

  sop="$h/catalog/prompts/lookback-cluster.md"
  [ -r "$sop" ] || { _lbc_log "cluster: prompt $sop missing, clustering skipped"; return 75; }
  min="${LOOKBACK_CLUSTER_MIN:-2}"
  case "$min" in ''|*[!0-9]*|0) _lbc_log "cluster: LOOKBACK_CLUSTER_MIN=$min is not a positive integer, using 2"; min=2 ;; esac

  # shellcheck source=lane-model.sh
  . "$h/bin/lib/lane-model.sh" || { _lbc_log "cluster: bin/lib/lane-model.sh could not be loaded, clustering skipped"; return 75; }
  model=$(lane_model LOOKBACK_MODEL lookback.cluster) \
    && runner=$(lane_model_ladder lookback.cluster) \
    || { _lbc_log "cluster: no model route for role lookback.cluster, clustering skipped"; return 75; }
  runner=$(printf '%s\n' "$runner" | awk -F'\t' 'NR==1{print $3}')
  if [ "$runner" != claude ]; then
    HARNESS="$h" "$h/bin/alert-line.sh" "[lookback] lookback.cluster routes to runner ${runner:-<none>}; only the claude runner is context-metered, so the ceiling cannot be enforced. Clustering skipped. Route lookback.cluster to claude (PUT /api/model-routes/lookback.cluster) to re-enable"
    _lbc_log "cluster: lookback.cluster routes to runner ${runner:-<none>}, not claude, clustering skipped"
    return 75
  fi

  in_fp=$(jq -c '.items' "$bundle" | sha1sum | cut -c1-40)
  marker="$run_dir/cluster-call.$in_fp.done"
  if [ -e "$marker" ]; then
    _lbc_log "cluster: already called for this bundle ($marker), re-parsing the saved answer"
  else
    local groups items prompt
    groups=$(jq -c --argjson min "$min" "$(lookback_item_match_jq)"'
      [.items[] | . as $i
        | (((.files // [])[] | {k: "file", v: ., id: $i.id}),
           (select(.lane != null) | {k: "lane", v: .lane, id: .id}),
           (select((.reason // "") != "") | {k: "reason", v: (.reason | lookback_reason_family), id: .id}))]
      | group_by([.k, .v])
      | map({key_kind: .[0].k, key_value: .[0].v, item_ids: (map(.id) | unique)})
      | map(select((.item_ids | length) >= $min))
      | sort_by(-(.item_ids | length), .key_kind, .key_value) | .[]' "$bundle")
    items=$(jq -c '.items[] | {id, source, project, lane, files, pr, reason: ((.reason // "") | .[0:300]), comment: (.comment.text? // null)}' "$bundle")
    prompt="$(cat "$sop")

## Candidate groups
$groups

## Items
$items"
    AGENT_CALL_BUDGET_USD="${LOOKBACK_MAX_USD:-15}" AGENT_CALL_RUNNERS="$runner" "$h/bin/agent-call.sh" lookback lookback "$model" 1800 "$run_dir/cluster-run.txt" "$prompt" >/dev/null
    rc=$?
    if [ "$rc" != 0 ]; then
      HARNESS="$h" "$h/bin/alert-line.sh" "lookback: clustering call rc=$rc"
      _lbc_log "cluster: clustering call rc=$rc"
      return 1
    fi
    touch "$marker"
  fi

  raw=$(cat "$run_dir/cluster-run.txt" 2>/dev/null)
  ans=""
  if printf '%s' "$raw" | jq -s -e 'length == 1 and (.[0] | type == "array")' >/dev/null 2>&1; then
    ans="$raw"
  elif [ "$(printf '%s\n' "$raw" | grep -c '^```json[[:space:]]*$')" = 1 ]; then
    ans=$(printf '%s\n' "$raw" | awk '/^```json[[:space:]]*$/{f=1;next} f&&/^```/{exit} f')
    printf '%s' "$ans" | jq -s -e 'length == 1 and (.[0] | type == "array")' >/dev/null 2>&1 || ans=""
  fi
  if [ -z "$ans" ]; then
    HARNESS="$h" "$h/bin/alert-line.sh" "lookback: clustering output unparseable ($run_dir/cluster-run.txt)"
    _lbc_log "cluster: output unparseable, nothing written"
    echo "invalid: unparseable"
    return 2
  fi

  res=$(printf '%s' "$ans" | jq -c --slurpfile b "$bundle" --argjson min "$min" "$(lookback_item_match_jq)"'
    def s: type == "string" and length > 0;
    def strip: gsub(" — "; ", ") | gsub("—"; "-");
    ($b[0].items | map({key: (.id | tostring), value: .}) | from_entries) as $by
    | def judge($seen):
        if type != "object" then null
        elif (.key_kind | IN("file", "lane", "reason") | not) or (.key_value | s | not) then null
        elif (.item_ids | type) != "array" or (.item_ids | all(type == "string") | not) then null
        elif ([.title, .cause, .proposed_fix] | all(s) | not) then null
        else
          .key_kind as $k
          | (if $k == "reason" then .key_value | lookback_reason_family else .key_value end) as $v
          | (.item_ids | unique) as $ids
          | (if .target == "app" then "app" else "harness" end) as $t
          | (if $t == "harness" then "cromford" else .project end) as $p
          | [$ids[] | $by[.]] as $its |
          if ($v | s | not) or ($its | any(. == null)) then null
          elif ($ids | any($seen[.] == true)) or ($ids | length) < $min then null
          elif $t == "app" and (($p | s | not) or $p == "cromford") then null
          elif $t == "harness" and (($its | all(.project == "cromford")) or $k == "lane"
                 or ($k == "file" and ($v | test("^(bin|cron|catalog|worker)/")))) == false then null
          elif ($its | all(item_matches($k; $v; $p)) | not) then null
          else {key_kind: $k, key_value: $v, item_ids: $ids, target: $t, project: $p,
                title: (.title | strip), cause: (.cause | strip), proposed_fix: (.proposed_fix | strip)}
          end
        end;
    reduce .[] as $c ({seen: {}, ok: [], bad: 0};
      . as $st | ($c | judge($st.seen)) as $r
      | if $r == null then .bad += 1
        else .ok += [$r] | .seen += ($r.item_ids | map({(.): true}) | add) end)
    | {ok, bad}') || {
    HARNESS="$h" "$h/bin/alert-line.sh" "lookback: cluster validator failed on $run_dir/cluster-run.txt"
    _lbc_log "cluster: validator failed, nothing written"
    return 1
  }

  local n i c fps="" bad
  n=$(jq '.ok | length' <<<"$res"); bad=$(jq '.bad' <<<"$res")
  for ((i = 0; i < n; i++)); do
    c=$(jq -c ".ok[$i]" <<<"$res")
    fps="$fps$(lookback_fingerprint "$(jq -r .target <<<"$c")" "$(jq -r .project <<<"$c")" \
      "$(jq -r .key_kind <<<"$c")" "$(jq -r .key_value <<<"$c")")
"
  done
  jq -c --arg fps "$fps" '($fps | split("\n")) as $f
    | [.ok | to_entries[] | {fingerprint: $f[.key]} + .value]
    | sort_by(-(.item_ids | length), .fingerprint)' <<<"$res" > "$out.tmp" \
    && mv "$out.tmp" "$out" || { rm -f "$out.tmp"; _lbc_log "cluster: could not write $out"; return 1; }
  echo "invalid: $bad"
  _lbc_log "cluster: $n valid, $bad invalid"
  return 0
}
