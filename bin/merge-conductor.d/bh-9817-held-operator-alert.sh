# shellcheck shell=bash
# bin/merge-conductor.d/bh-9817-held-operator-alert.sh - A PR HELD FOR A PERSON
# MUST REACH A PERSON (BH-9817). Sourced by bin/merge-conductor.sh (the BH-7453
# fragment block). Called by mc_bm_proof (bh-9403-before-merge-proof.sh) in its
# `hold` arm, with pr_worker's SLUG, NUM, KEY, P, ACTIONS and KILL in scope.
#
# mc_bm_held_alert reads the PR's comments (the same ETag'd REST read
# mc_hotfix_proof just made). When the newest hotfix-migrate proof says
# decision=needs-operator, the PR is held since the OLDEST marker of the trailing
# run of needs-operator markers with that fp (GitHub's created_at, so it
# survives a box move). Held longer than the row hotfix_migrate.held_alert_hours
# (code fallback 6): one alert HELD_NEEDS_OPERATOR with the PR, the held hours,
# the file and the operator step (the proof's `Operator step (<path>): <step>`
# lines). Then at most one more per hotfix_migrate.held_alert_repeat_hours (code
# fallback 24): the attempt key is `bmheld <KEY> <fp12> <bucket>`,
# bucket = (held - row) / repeat window, the mark is put
# before the send. Observe mode (ACTIONS != 1 or KILL=1): one WOULD log line.
# A failed comments read, another decision, or no marker: nothing, rc 0.

# _mc_bm_hours_row <key> <fallback>: a settings row read as an integer 1..720;
# absent or invalid = <fallback>, the documented code fallback of that row.
_mc_bm_hours_row() {
  local v=""
  if ! command -v setting_get >/dev/null 2>&1; then
    command -v _hmk_ensure_client >/dev/null 2>&1 && _hmk_ensure_client >/dev/null 2>&1
  fi
  command -v setting_get >/dev/null 2>&1 && v=$(setting_get "$1" 2>/dev/null)
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  if grep -qxE '[0-9]{1,3}' <<<"$v" && [ "$v" -ge 1 ] && [ "$v" -le 720 ]; then
    printf '%s' "$v"
  else
    printf '%s' "$2"
  fi
}

# _mc_bm_held_hours: the row hotfix_migrate.held_alert_hours (code fallback 6).
_mc_bm_held_hours() { _mc_bm_hours_row hotfix_migrate.held_alert_hours 6; }

# _mc_bm_repeat_hours: the row hotfix_migrate.held_alert_repeat_hours, the
# window between two alerts for the same held PR (code fallback 24).
_mc_bm_repeat_hours() { _mc_bm_hours_row hotfix_migrate.held_alert_repeat_hours 24; }

# mc_bm_operator_applied: rc 0 when the newest hotfix-migrate proof says
# decision=needs-operator AND the production ledger (mmh_decide) answers
# `applied` for this head. That is the state after a person did the operator
# step, so the hold has no more reason. Any other answer (missing, unreadable,
# none, off, lane, no mmh_decide, a failed comments read, another decision):
# rc 1, and the row stays parked. mmh_decide caches its answer per (KEY, HEAD),
# so mc_mig_hold's own mmh_decide call on the same tick costs no second probe.
mc_bm_operator_applied() {
  local comments dec
  [ -n "${P:-}" ] && [ -n "${SLUG:-}" ] && [ -n "${NUM:-}" ] && [ -n "${KEY:-}" ] && [ -n "${HEAD:-}" ] || return 1
  command -v mmh_decide >/dev/null 2>&1 || return 1
  command -v mc_rest_var >/dev/null 2>&1 || return 1
  mc_rest_var comments _gh_rest_list "$SLUG" "issues/$NUM/comments" 1000 '.' 2>/dev/null || return 1
  dec=$(printf '%s' "$comments" | jq -r '
    [.[] | select((.body // "") | startswith("<!-- hotfix-migrate-proof "))] | last | (.body // "")
    | split("\n") | (.[0] // "") | (try capture("decision=(?<d>[A-Za-z-]+)").d catch "")' 2>/dev/null) || return 1
  [ "$dec" = needs-operator ] || return 1
  command -v mc_step >/dev/null 2>&1 && mc_step migration-hold
  mmh_decide "$P" "$SLUG" "$NUM" "$KEY" "$HEAD"
  [ "${MMH_VERDICT:-}" = applied ]
}

mc_bm_held_alert() {
  local comments info fp since steps hrs rep now t0 age held bucket ak text url
  [ -n "${SLUG:-}" ] && [ -n "${NUM:-}" ] && [ -n "${KEY:-}" ] || return 0
  command -v mc_rest_var >/dev/null 2>&1 || return 0
  mc_rest_var comments _gh_rest_list "$SLUG" "issues/$NUM/comments" 1000 '.' 2>/dev/null || return 0
  info=$(printf '%s' "$comments" | jq -c '
    def mk: ((.body // "") | split("\n") | (.[0] // ""));
    def dec: (mk | (try capture("decision=(?<d>[A-Za-z-]+)").d catch ""));
    def fp:  (mk | (try capture("fp=(?<f>[0-9a-fA-F]+)").f catch ""));
    [.[] | select((.body // "") | startswith("<!-- hotfix-migrate-proof "))] as $all
    | ($all | last) as $n
    | if $n == null or ($n | dec) != "needs-operator" then empty else
        ($n | fp) as $f
        | (reduce ($all | reverse[]) as $x ({stop:false, since:null};
             if .stop then .
             elif ($x | dec) == "needs-operator" and ($x | fp) == $f then .since = ($x.created_at // null)
             else .stop = true end) | .since) as $s
        | {fp:$f, since:$s, body:($n.body // "")}
      end' 2>/dev/null) || return 0
  [ -n "$info" ] || return 0
  fp=$(jq -r '.fp // ""' <<<"$info"); since=$(jq -r '.since // ""' <<<"$info")
  [ -n "$fp" ] && [ -n "$since" ] || return 0
  t0=$(date -u -d "$since" +%s 2>/dev/null) || return 0
  steps=$(jq -r '.body' <<<"$info" | tr -d '\r' | sed -nE 's/^Operator step \((.*)\): (.*)$/\1: \2/p' | paste -sd ';' - | sed 's/;/; /g')
  [ -n "$steps" ] || steps="see the proof comment"
  hrs=$(_mc_bm_held_hours)
  rep=$(_mc_bm_repeat_hours)
  now="${MC_NOW_EPOCH:-$(date +%s)}"
  age=$(( now - t0 ))
  [ "$age" -ge $(( hrs * 3600 )) ] || return 0
  held=$(( age / 3600 ))
  bucket=$(( (age - hrs * 3600) / (rep * 3600) ))
  ak="bmheld $KEY ${fp:0:12} $bucket"
  url="https://github.com/$SLUG/pull/$NUM"
  text=$(printf '%s held %sh on a needs-operator migration proof (row hotfix_migrate.held_alert_hours = %s): %s' \
    "$url" "$held" "$hrs" "$steps" | tr '\t\r\n' '   ' | cut -c1-500)
  if [ "${ACTIONS:-0}" != 1 ] || [ "${KILL:-0}" = 1 ]; then
    command -v mc_log >/dev/null 2>&1 && mc_log "$KEY WOULD alert HELD_NEEDS_OPERATOR (observe mode: nothing sent): $text"
    return 0
  fi
  command -v mc_attempt_has >/dev/null 2>&1 && mc_attempt_has "$ak" 2>/dev/null && return 0
  # The mark before the send: a crash costs one alert, never a storm.
  command -v mc_attempt_put >/dev/null 2>&1 && mc_attempt_put "$ak"
  command -v mc_alert >/dev/null 2>&1 && mc_alert "$KEY" HELD_NEEDS_OPERATOR "$text"
  return 0
}
