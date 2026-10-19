#!/bin/bash
# shellcheck shell=bash
# bin/lib/deploy-main-ci.sh — BH-6746 (wave 3 of #6541): the deploy train
# departs only on a sha whose `main-ci` commit status is `success`. Sourced by
# bin/deploy-train.sh, never run.
#
# WHY. A direct landing (BH-6745) puts a merge on main that no merge-queue batch
# tested; Harness CI then tests it on the push and posts `main-ci=success|
# failure` on the sha (.github/workflows/harness-ci.yml, job main-ci). Without
# this gate the train departs on origin/main HEAD whatever CI said about it.
#
# THE SWITCH. bin/deploy-train.sh calls this only with DEPLOY_MAIN_CI_GATE=1
# (a deploy-train lane knob, default 0 = off): only a repo whose CI posts
# `main-ci` can turn it on, or every departure would end MAIN_CI_UNKNOWN.
#
# dmc_state <project> <slug> <sha>
#   Prints success | failure | none | unreadable, always rc 0.
#   A cached success ($HARNESS/state/deploy-main-ci/<project>/<sha> holds
#   `success`) answers with no read. No HARNESS (or H) is unreadable: this
#   lib never builds a path from an empty root. Else ONE REST read,
#   `${DEPLOY_MAIN_CI_GH:-gh} api repos/<slug>/commits/<sha>/statuses?per_page=100`;
#   the newest `main-ci` entry (the API lists newest first) gives success or
#   failure; no entry, or another state (pending, error), is none. A read that
#   fails or does not parse is unreadable. Only success is cached: a re-run of
#   a red push can still turn the sha green.
#
# dmc_decide <project> <slug> <sha>
#   Sets DMC_LINE (one log line) and returns:
#     0 depart   MAIN_CI_GREEN <sha8>
#     1 red      MAIN_CI_RED <sha8>; the train departs on the next green head
#     2 wait     MAIN_CI_WAIT <sha8> (<m>m of <bound>m, main-ci <state>)
#     3 unknown  MAIN_CI_UNKNOWN <sha8> after <m>m, at or past the bound
#                DEPLOY_MAIN_CI_WAIT_MIN (default 45; not a positive integer:
#                45). The first UNKNOWN tick of a sha also writes ONE ALERTS
#                line (bin/alert-line.sh --id deploy-main-ci-unknown-<p>-<sha8>);
#                the `<sha>.unknown` marker stops a second one.
#   The wait is counted from the first tick that saw the sha (`<sha>.seen`,
#   written once). RETENTION: every call deletes marker files older than 7
#   days in the project's directory; a sha that old is long past any bound.
#
# DMC_NOW (epoch seconds) is the clock seam for the tests.
# gh-rest: no-graphql

_dmc_now() { if [ -n "${DMC_NOW:-}" ]; then printf '%s' "$DMC_NOW"; else date +%s; fi; }
# _dmc_dir <project> — rc 1 with no harness root (never a path built from "").
_dmc_dir() { local r="${HARNESS:-${H:-}}"; [ -n "$r" ] || return 1; printf '%s/state/deploy-main-ci/%s' "$r" "$1"; }

dmc_state() {
  local d f j s
  d=$(_dmc_dir "$1") || { echo unreadable; return 0; }
  f="$d/$3"
  [ "$(cat "$f" 2>/dev/null)" = success ] && { echo success; return 0; }
  j=$("${DEPLOY_MAIN_CI_GH:-gh}" api "repos/$2/commits/$3/statuses?per_page=100" 2>/dev/null) || { echo unreadable; return 0; }
  s=$(jq -r 'if type == "array" then ([.[] | select(.context? == "main-ci")][0].state // "none")
             else error("not a list") end' <<<"$j" 2>/dev/null) || { echo unreadable; return 0; }
  case "$s" in
    success) { mkdir -p "$d" && printf 'success\n' > "$f"; } 2>/dev/null; echo success ;;
    failure) echo failure ;;
    *) echo none ;;
  esac
  return 0
}

dmc_decide() {
  local p="$1" slug="$2" sha="$3" d st bound now seen age
  d=$(_dmc_dir "$p") || { DMC_LINE="MAIN_CI_WAIT ${sha:0:8} (no harness root to keep the wait in) — not departing"; return 2; }
  mkdir -p "$d" 2>/dev/null
  find "$d" -type f -mtime +7 -delete 2>/dev/null
  st=$(dmc_state "$p" "$slug" "$sha")
  case "$st" in
    success) DMC_LINE="MAIN_CI_GREEN ${sha:0:8} — main-ci=success, departing"; return 0 ;;
    failure) DMC_LINE="MAIN_CI_RED ${sha:0:8} — main-ci=failure, not departing; the train departs on the next green head"; return 1 ;;
  esac
  bound="${DEPLOY_MAIN_CI_WAIT_MIN:-45}"
  case "$bound" in ''|*[!0-9]*|0) bound=45 ;; esac
  now=$(_dmc_now)
  [ -s "$d/$sha.seen" ] || printf '%s\n' "$now" > "$d/$sha.seen" 2>/dev/null
  seen=$(cat "$d/$sha.seen" 2>/dev/null); case "$seen" in ''|*[!0-9]*) seen="$now" ;; esac
  age=$(( (now - seen) / 60 ))
  if [ "$age" -lt "$bound" ]; then
    DMC_LINE="MAIN_CI_WAIT ${sha:0:8} (${age}m of ${bound}m, main-ci $st) — not departing yet"
    return 2
  fi
  DMC_LINE="MAIN_CI_UNKNOWN ${sha:0:8} after ${age}m (main-ci $st, bound ${bound}m) — not departing"
  if [ ! -e "$d/$sha.unknown" ]; then
    : > "$d/$sha.unknown" 2>/dev/null
    "${HARNESS:-${H:-}}/bin/alert-line.sh" --id "deploy-main-ci-unknown-$p-${sha:0:8}" --project "$p" \
      "[$p] DEPLOY TRAIN: MAIN_CI_UNKNOWN — ${sha:0:8} has no main-ci status after ${age}m (main-ci $st); the train does not depart until main-ci=success is on origin/main HEAD" \
      >/dev/null 2>&1 || true
  fi
  return 3
}
