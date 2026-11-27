# shellcheck shell=bash
# bin/lib/unblock/change-gate.sh — the unblock lane reads a PR from GitHub only
# after a change (BH-10197). Sourced by bin/lib/unblock/collectors/queue.sh and
# review.sh. Defines functions only: no set -e, no exit.
#
# THE STORE is the D1 table unblock_change_marks, one row per (repo, site, pr),
# through two jobs worker routes (worker/jobs/src/routes/unblock-change-marks.js):
#   POST /api/unblock/change-marks/check   per PR: due or not, the reason, the
#                                          mark to commit, the stored fields
#   POST /api/unblock/change-marks/commit  one newer-only upsert of the marks
# The mark is the newest wakes.id for the PR and its ticket issue (a worker
# sequence). No state file.
#
# THE STEP is ubp_step (bin/lib/unblock/prr.sh): the settings row
# lane.unblock.gh_source, read once per tick by bin/unblock.sh as GH_SOURCE.
#   off     no gate call at all (ubg_check rc 3); every PR is read.
#   shadow  check and commit; every PR is read as in off. A PR the gate would
#           skip whose fresh answer differs from its stored one is one
#           GATE_SHADOW line. A failed check reads as off.
#   record  a PR that is not due, and whose stored fields hold every answer
#           the collector needs, makes 0 GitHub-only reads: the answers come
#           from the stored fields. A failed check is UNKNOWN: the caller
#           reads nothing for those PRs, builds no record and commits nothing.
#
# A gate dir <G> (a fresh directory the caller owns) holds one check:
#   ans.json   the check answer      status  ok | unknown | off | unreadable
#   put-<pr>.json  one commit item   skip-<pr>  a PR served from its row
#   stored     the commit's count    site, slug, step
#
#   ubg_check <slug> <site> <items-jsonl-file> <G>
#       <items-jsonl-file>: one {pr, head, issue?} per line. Step off: rc 3,
#       no call. Else one POST check with backstop_s = UNBLOCK_GATE_BACKSTOP_S.
#       rc 0 = a valid answer in <G>/ans.json (an empty item list makes no
#       call). rc 1 = the call failed (http, rc 75, bad JSON, an item missing
#       from the answer): state unknown in record, unreadable in shadow.
#   ubg_skip <G> <pr> <key>...
#       rc 0 = serve this PR from its row: step record, a valid answer, the PR
#       is not due and its stored fields hold every <key>. Writes skip-<pr>.
#       rc 1 = read it.
#   ubg_stored <G> <pr> <key>
#       One field at a time: prints the stored JSON value of <key> and rc 0
#       under the same rule as ubg_skip (no skip file); rc 1 = read it.
#   ubg_fresh <G> <pr>
#       Prints the PR's mark and rc 0 when a read of this PR may be served
#       from the state/unblock-prr/ file cache (bin/lib/unblock/prr.sh
#       ubp_cached) only under that mark and only from this tick (the caller
#       passes it as UBP_FRESH): step record, a valid answer, and the PR is due
#       for a change (head, wake, unsettled, backstop) or not due at all (a
#       field was missing). rc 1 for first (no row) and off: the reads run as
#       before the gate.
#   ubg_put <G> <pr> <head> <fresh-fields-json>
#       Call it only when every gated read of the PR this tick succeeded. A due
#       PR stores the fresh fields only (the stored ones are older than the
#       mark); a PR that is not due stores its stored fields plus the fresh
#       ones (a field that was missing); a PR that is not due with {} fresh
#       is left as it is. The mark and settled of the check answer go with
#       them, to put-<pr>.json. In shadow, a PR the
#       gate would skip whose fresh value of a stored key differs logs one
#       GATE_SHADOW <site> <repo>#<pr> field=<k,...> line. No valid answer or
#       a PR missing from it: nothing.
#   ubg_commit <G>
#       One POST commit of every put-<pr>.json (none: no call). rc 0 and the
#       count in <G>/stored; rc 1 on any failure (the marks stay, so the next
#       tick reads those PRs again). Never retries.
#   ubg_log <G> <unknown-count>
#       One line in logs/unblock.log: gate <site> <repo> step=<s> checked=<n>
#       due=<n> skipped=<n> would_skip=<n> unknown=<n> stored=<n>. The counts
#       come from the answer, the skip files and the commit answer. In shadow
#       with a failed check: gate <site> <repo> unreadable (shadow: no effect).
#
# The root is ${HARNESS:-${H:-}} (D43): with no root no line is logged.
[ -n "${_UBG_LOADED:-}" ] && return 0
_UBG_LOADED=1
# fallback only: the knob is UNBLOCK_GATE_BACKSTOP_S in catalog/lanes.d/unblock.knobs.d/UNBLOCK_GATE_BACKSTOP_S.json
_UBG_DEFAULT_BACKSTOP_S=3600

_ubg_step() { if declare -F ubp_step >/dev/null; then ubp_step; else printf 'off\n'; fi; }

_ubg_back() {
  local v="${UNBLOCK_GATE_BACKSTOP_S:-}"
  if [[ $v =~ ^[0-9]{1,5}$ ]] && [ "$((10#$v))" -le 86400 ]; then printf '%s' "$((10#$v))"; else printf '%s' "$_UBG_DEFAULT_BACKSTOP_S"; fi
}

_ubg_logline() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$h/logs/unblock.log" 2>/dev/null || true
}

# _ubg_fail <G> <step>: a failed check is unknown in record, unreadable in shadow.
_ubg_fail() {
  if [ "$2" = record ]; then echo unknown > "$1/status"; else echo unreadable > "$1/status"; fi
  rm -f "$1/ans.json"
}

ubg_check() {
  local slug="${1:-}" site="${2:-}" items="${3:-}" g="${4:-}" step body ans rc=0 n
  [ -n "$g" ] && [ -d "$g" ] || return 1
  step=$(_ubg_step)
  printf '%s' "$step" > "$g/step"; printf '%s' "$site" > "$g/site"; printf '%s' "$slug" > "$g/slug"
  if [ "$step" = off ]; then echo off > "$g/status"; return 3; fi
  n=$(jq -s 'length' "$items" 2>/dev/null) || { _ubg_fail "$g" "$step"; return 1; }
  if [ "$n" = 0 ]; then echo '{"items":[]}' > "$g/ans.json"; echo ok > "$g/status"; return 0; fi
  body=$(jq -sc --arg r "$slug" --arg s "$site" --argjson b "$(_ubg_back)" '{repo: $r, site: $s, backstop_s: $b, items: .}' "$items" 2>/dev/null) \
    || { _ubg_fail "$g" "$step"; return 1; }
  declare -F _jobs_req >/dev/null || { _ubg_fail "$g" "$step"; return 1; }
  ans=$(JOBS_ALERT=0 _jobs_req POST /api/unblock/change-marks/check "$body" 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] || { _ubg_fail "$g" "$step"; return 1; }
  # Every PR sent must be in the answer, once, with a due bool: else unknown.
  jq -e --argjson want "$(jq -sc '[.[].pr] | sort' "$items")" '
      (.items | type) == "array" and ([.items[].pr] | sort) == $want
      and all(.items[]; (.due | type) == "boolean" and (.mark | type) == "number" and (.settled == 0 or .settled == 1)
                        and (.fields | type) == "object" and (.reason | type) == "string")' <<<"$ans" >/dev/null 2>&1 \
    || { _ubg_fail "$g" "$step"; return 1; }
  printf '%s\n' "$ans" > "$g/ans.json"
  echo ok > "$g/status"
  return 0
}

_ubg_ok() { [ "$(cat "$1/status" 2>/dev/null)" = ok ] && [ -f "$1/ans.json" ]; }
_ubg_item() { jq -c --argjson p "$2" 'first(.items[] | select(.pr == $p)) // empty' "$1/ans.json" 2>/dev/null; }

ubg_skip() {
  local g="${1:-}" pr="${2:-}" it
  shift 2 2>/dev/null || return 1
  _ubg_ok "$g" && [ "$(cat "$g/step")" = record ] || return 1
  it=$(_ubg_item "$g" "$pr"); [ -n "$it" ] || return 1
  jq -e --args '.due == false and (. as $i | all($ARGS.positional[]; . as $k | $i.fields | has($k)))' "$@" <<<"$it" >/dev/null 2>&1 || return 1
  : > "$g/skip-$pr"
  return 0
}

ubg_stored() {
  local g="${1:-}" pr="${2:-}" k="${3:-}" it
  _ubg_ok "$g" && [ "$(cat "$g/step")" = record ] || return 1
  it=$(_ubg_item "$g" "$pr"); [ -n "$it" ] || return 1
  # jq -c, not -e: a stored false is a value (rc 5 only from error()).
  jq -c --arg k "$k" 'if .due == false and (.fields | has($k)) then .fields[$k] else error("read") end' <<<"$it" 2>/dev/null
}

ubg_fresh() {
  local g="${1:-}" pr="${2:-}" it
  _ubg_ok "$g" && [ "$(cat "$g/step")" = record ] || return 1
  it=$(_ubg_item "$g" "$pr"); [ -n "$it" ] || return 1
  jq -er 'if .due == false or (.reason | IN("head", "wake", "unsettled", "backstop")) then .mark else empty end' <<<"$it" 2>/dev/null
}

ubg_put() {
  local g="${1:-}" pr="${2:-}" head="${3:-}" fresh="${4:-}" it diff
  _ubg_ok "$g" || return 0
  it=$(_ubg_item "$g" "$pr"); [ -n "$it" ] || return 0
  jq -e 'type == "object"' <<<"$fresh" >/dev/null 2>&1 || return 0
  if [ "$(cat "$g/step")" = shadow ]; then
    diff=$(jq -r --argjson f "$fresh" 'if .due then "" else
        [.fields as $s | $f | to_entries[] | .key as $k | select(($s | has($k)) and $s[$k] != .value) | $k] | join(",") end' <<<"$it" 2>/dev/null)
    [ -n "$diff" ] && _ubg_logline "GATE_SHADOW $(cat "$g/site") $(cat "$g/slug")#$pr field=$diff"
  fi
  # A PR not due with nothing read keeps its row as it is (its backstop runs on).
  jq -e --argjson f "$fresh" '.due == false and $f == {}' <<<"$it" >/dev/null 2>&1 && return 0
  # Due: the stored fields are older than the mark, so only the fresh ones go.
  jq -c --arg h "${head,,}" --argjson f "$fresh" '{pr, head: $h, mark, settled, fields: (if .due then $f else .fields + $f end)}' <<<"$it" > "$g/put-$pr.json" 2>/dev/null \
    || rm -f "$g/put-$pr.json"
  return 0
}

ubg_commit() {
  local g="${1:-}" body ans rc=0 n
  _ubg_ok "$g" || return 0
  n=$(find "$g" -maxdepth 1 -name 'put-*.json' | wc -l)
  [ "$n" -gt 0 ] || { echo 0 > "$g/stored"; return 0; }
  body=$(cat "$g"/put-*.json | jq -sc --arg r "$(cat "$g/slug")" --arg s "$(cat "$g/site")" '{repo: $r, site: $s, items: .}') || return 1
  declare -F _jobs_req >/dev/null || return 1
  ans=$(JOBS_ALERT=0 _jobs_req POST /api/unblock/change-marks/commit "$body" 2>/dev/null) || rc=$?
  if [ "$rc" = 0 ] && jq -e '(.stored | type) == "number"' <<<"$ans" >/dev/null 2>&1; then
    jq -r '.stored' <<<"$ans" > "$g/stored"
    return 0
  fi
  echo failed > "$g/stored"
  _ubg_logline "gate $(cat "$g/site") $(cat "$g/slug") commit failed rc=$rc (the marks stay; the next tick reads again)"
  return 1
}

ubg_log() {
  local g="${1:-}" unk="${2:-0}" st site slug step c=0 du=0 sk=0 ws=0 stored=0
  site=$(cat "$g/site" 2>/dev/null); slug=$(cat "$g/slug" 2>/dev/null); step=$(cat "$g/step" 2>/dev/null)
  st=$(cat "$g/status" 2>/dev/null)
  case "$st" in
    off) return 0 ;;
    unreadable) _ubg_logline "gate $site $slug unreadable (shadow: no effect)"; return 0 ;;
  esac
  if [ "$st" = ok ]; then
    read -r c du ws < <(jq -r '[(.items | length), ([.items[] | select(.due)] | length), ([.items[] | select(.due | not)] | length)] | @tsv' "$g/ans.json")
    [ "$step" = shadow ] || ws=0
    sk=$(find "$g" -maxdepth 1 -name 'skip-*' | wc -l)
  else
    ws=0
  fi
  [[ $unk =~ ^[0-9]+$ ]] || unk=0
  stored=$(cat "$g/stored" 2>/dev/null); [ -n "$stored" ] || stored=0
  _ubg_logline "gate $site $slug step=$step checked=$c due=$du skipped=$sk would_skip=$ws unknown=$unk stored=$stored"
}
