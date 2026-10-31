# shellcheck shell=bash
# bin/merge-conductor.d/bh-8781-prod-red-hold.sh - A RED PRODUCTION DEPLOY
# HOLDS THE MERGE (BH-8781). Sourced by bin/merge-conductor.sh (the BH-7453
# fragment block); no side effect at source time.
#
# The red record is .projects[<p>].prod_red in state/vercel-deploy-status.json,
# written every 4 minutes by the hub lane bin/vercel-deploy-snapshot.sh: set
# while the newest production deploy of the project is ERROR, null once the
# newest finished one is READY. Both lanes run on the hub, so this is a read of
# one local file: no network, no lib, no shell option change.
#
# mc_prod_red_hold — pr_worker calls it in the READY arm right after the
# main-red freeze, before the dep gate, the budget and every gh write, with
# pr_worker's P KEY HEAD SLUG NUM URL RAWLBL in scope. rc 0 = HELD: the row
# stays READY with the ready-why reason `production red since <since>, commit
# <sha8>`, one log line per (PR, head), and pr_worker returns. rc 1 = go on.
# A PR labelled $MC_MAIN_RED_LABEL (fix-main-red) or hotfix, or one whose whole
# diff is test files (main_red_exempt), merges through the hold: the fix for a
# red production must be able to land.
#
# FAIL OPEN. A missing, unparseable or stale snapshot (generated_at older than
# MC_PROD_RED_MAX_AGE_S) holds nothing and writes one line per project-hour: a
# dead snapshot lane must not freeze every Vercel project's queue.
#
# Knobs: MC_PROD_RED_HOLD (1 on, 0 off; per project:
# lane.merge-conductor.<project>.mc_prod_red_hold), MC_PROD_RED_MAX_AGE_S.
# Test seams only: MC_PROD_RED_SNAPSHOT (the file), MC_PROD_RED_NOW (the clock).
# Tests: tests/merge-conductor-prod-red-hold.bh-8781-test.sh.

# _mc_prr_knob <ENV> <fallback> — lane.merge-conductor[.<p>].<env>, else the env
# var, else the fallback. Not a whole number reads as the fallback.
_mc_prr_knob() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor "$1" "${P:-}" 2>/dev/null); fi
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  printf '%s' "$v"
}

# _mc_prr_max_age — the snapshot age in seconds past which it reads unknown.
_mc_prr_max_age() {
  local v
  # fallback 1800: settings row lane.merge-conductor.mc_prod_red_max_age_s (catalog/lanes.d/merge-conductor.knobs.d/MC_PROD_RED_MAX_AGE_S.json)
  v=$(_mc_prr_knob MC_PROD_RED_MAX_AGE_S 1800)
  case "$v" in 0*) v=1800 ;; esac
  printf '%s' "$v"
}

# mc_prod_red_state <project>
#   rc 0 red: prints `since<TAB>sha8<TAB>id`
#   rc 1 not red (no record, a null record, or the project is not in the file)
#   rc 2 unknown (no file, junk, or older than MC_PROD_RED_MAX_AGE_S): prints
#        the file's generated_at, or `none`
mc_prod_red_state() {
  local p="${1:-}" f max now out
  [ -n "$p" ] || return 1
  f="${MC_PROD_RED_SNAPSHOT:-${H:-${HARNESS:-}}/state/vercel-deploy-status.json}"
  [ -r "$f" ] || { printf 'none'; return 2; }
  max=$(_mc_prr_max_age)
  now="${MC_PROD_RED_NOW:-$(date -u +%s)}"
  case "$now" in ''|*[!0-9]*) now=$(date -u +%s) ;; esac
  out=$(jq -r --arg p "$p" --argjson now "$now" --argjson max "$max" '
    if type != "object" then "unknown\tnone"
    else ((.generated_at // "") | tostring) as $ga
    | ($ga | sub(" "; "T") | try fromdateiso8601 catch null) as $g
    | if $g == null or ($now - $g) > $max then "unknown\t\(if $ga == "" then "none" else $ga end)"
      else ((.projects // {}) | if type == "object" then .[$p] else null end) as $r
      | (if ($r | type) == "object" then $r.prod_red else null end) as $red
      | if ($red | type) == "object" and (($red.since // "") | tostring) != ""
        then "red\t\($red.since)\t\($red.sha // "")\t\($red.id // "")"
        else "green" end
      end
    end' "$f" 2>/dev/null) || { printf 'none'; return 2; }
  case "$out" in
    red$'\t'*) printf '%s' "${out#red$'\t'}"; return 0 ;;
    green) return 1 ;;
    unknown$'\t'*) printf '%s' "${out#unknown$'\t'}"; return 2 ;;
  esac
  printf 'none'; return 2
}

# mc_prod_red_hold — rc 0 HELD, rc 1 go on. See the header.
mc_prod_red_hold() {
  [ -n "${P:-}" ] && [ -n "${KEY:-}" ] && [ -n "${HEAD:-}" ] || return 1
  # fallback 1: settings row lane.merge-conductor.mc_prod_red_hold (catalog/lanes.d/merge-conductor.knobs.d/MC_PROD_RED_HOLD.json)
  [ "$(_mc_prr_knob MC_PROD_RED_HOLD 1)" = 0 ] && return 1
  local st rc since sha id now mark
  st=$(mc_prod_red_state "$P"); rc=$?
  if [ "$rc" = 2 ]; then
    now="${MC_PROD_RED_NOW:-$(date -u +%s)}"
    mark="prodredunk $P $(date -u -d "@$now" +%Y%m%d%H 2>/dev/null)"
    mc_attempt_has "$mark" 2>/dev/null \
      || { mc_attempt_put "$mark"
           mc_log "prod-red: snapshot unreadable or older than $(_mc_prr_max_age)s for $P (generated_at ${st:-none}); not held"; }
    return 1
  fi
  [ "$rc" = 0 ] || return 1
  IFS=$'\t' read -r since sha id <<<"$st"
  if { command -v main_red_exempt >/dev/null 2>&1 && main_red_exempt "${SLUG:-}" "${NUM:-}" "${URL:-}" "$HEAD" "${RAWLBL:-}"; } \
     || { command -v hotfix_pr_is >/dev/null 2>&1 && hotfix_pr_is "${RAWLBL:-}"; }; then
    mc_attempt_has "prodredpass $KEY $HEAD" 2>/dev/null \
      || { mc_attempt_put "prodredpass $KEY $HEAD"
           mc_log "$KEY is exempt from the production-red hold (labelled ${MC_MAIN_RED_LABEL:-fix-main-red} or hotfix, or its whole diff is test files) — it may merge while $P production is red since $since"; }
    return 1
  fi
  mc_attempt_has "prodredhold $KEY $HEAD" 2>/dev/null \
    || { mc_attempt_put "prodredhold $KEY $HEAD"
         mc_log "$KEY READY and HELD: production red since $since, commit $sha (Vercel $id); it merges on the first tick after a READY production deploy"; }
  mc_ready_why "$KEY" "$HEAD" prod-red "production red since $since, commit $sha" logged
  return 0
}
