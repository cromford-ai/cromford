#!/bin/bash
# bin/lib/box-move/common.sh — the shared helpers of bin/box-move.sh (BH-8322).
# Sourced. bin/box-move.sh sets the globals these read before it calls them:
# BIN, BM_STATE (state/box-move/<newbox> on the hub), BM_TJ (its target.json)
# and BM_SSH_OPTS. Nothing here has a /root/harness default (D43).
#
#   bm_say <text>            one stamped stdout line
#   bm_refuse <text>         preflight refusal: one stderr line, one
#                            alert-line row (--id box-move-preflight), exit 3
#   bm_fail <text>           a step failed: one stderr line, exit 4
#   bm_is_posint / bm_is_uint / bm_is_name <value>
#   bm_rows_resolve <oldbox> <newbox>
#                            sets BM_BOX_ID, BM_OLD_IP, BM_PROJECTS (space
#                            list) and BM_REG_SOURCE from bin/fleet-conf.sh;
#                            refuses an unknown old box, an old box with no
#                            address, newbox == oldbox and a newbox that
#                            already runs a project
#   bm_tj_set <key> <value>  one field of target.json (tmp + mv)
#   bm_tj_get <key>          one field, empty when absent
#   bm_sh <ip> <script> [<arg>...]
#                            run a bash script on root@<ip>. The script rides
#                            base64 in argv, so stdin stays the caller's (the
#                            env pipe streams through it). An arg with a
#                            single quote is refused (rc 2).
#   bm_idle_exempt <app> <signals.json>
#                            rc 0 when bin/fly-idle-reaper.sh would answer
#                            `exempt` for <app>: an exact `apps` key wins,
#                            else the longest prefix that matches from the
#                            start; no match is `metrics`

bm_say() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [box-move] $*"; }
bm_refuse() {
  echo "box-move: refused: $*" >&2
  "$BIN/alert-line.sh" --id box-move-preflight "[box-move] refused: $*" >/dev/null 2>&1 || true
  exit 3
}
bm_fail() { echo "box-move: failed: $*" >&2; exit 4; }

bm_is_posint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 0 ] 2>/dev/null; }
bm_is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
bm_is_name() { [[ "$1" != *$'\n'* ]] && grep -qE '^[a-z0-9][a-z0-9-]{0,62}$' <<<"$1"; }

bm_rows_resolve() {
  local old="$1" new="$2" rows
  [ "$old" != "$new" ] || bm_refuse "the new box $new is the old box"
  rows=$("$BIN/fleet-conf.sh" --boxes-with-roles 2>/dev/null) || bm_refuse "bin/fleet-conf.sh --boxes-with-roles failed"
  BM_BOX_ID=$(awk -F'\t' -v b="$old" '$1 == b {print $2; exit}' <<<"$rows")
  [ -n "$BM_BOX_ID" ] || bm_refuse "the rows name no box $old"
  grep -qE '^[a-z][a-z0-9]*$' <<<"$BM_BOX_ID" || bm_refuse "the rows give $old a bad box id '$BM_BOX_ID'"
  BM_OLD_IP=$("$BIN/fleet-conf.sh" --tailnet-ip-of-box "$old" 2>/dev/null) || BM_OLD_IP=""
  [ -n "$BM_OLD_IP" ] || bm_refuse "the rows give $old no tailnet address"
  grep -qE '^[0-9A-Fa-f.:]+$' <<<"$BM_OLD_IP" || bm_refuse "the rows give $old a bad address '$BM_OLD_IP'"
  BM_PROJECTS=$("$BIN/fleet-conf.sh" --projects-on-box "$old" 2>/dev/null | tr '\n' ' ')
  BM_PROJECTS="${BM_PROJECTS% }"
  [ -z "$("$BIN/fleet-conf.sh" --projects-on-box "$new" 2>/dev/null)" ] \
    || bm_refuse "the rows already put a project on $new"
  BM_REG_SOURCE="${REGISTRY_SOURCE:-file}"
}

bm_tj_set() {
  mkdir -p "$BM_STATE" || return 1
  local cur='{}'
  [ -s "$BM_TJ" ] && cur=$(cat "$BM_TJ")
  jq -c --arg k "$1" --arg v "$2" '.[$k]=$v' <<<"$cur" > "$BM_TJ.tmp" && mv -f "$BM_TJ.tmp" "$BM_TJ"
}
bm_tj_get() { jq -r --arg k "$1" '.[$k] // empty' "$BM_TJ" 2>/dev/null; }

bm_sh() {
  local ip="$1" s="$2" b a q=""
  shift 2
  for a in "$@"; do
    case "$a" in *"'"*) echo "box-move: refused: a remote argument holds a quote" >&2; return 2 ;; esac
    q="$q '$a'"
  done
  b=$(printf '%s' "$s" | base64 -w0)
  ssh "${BM_SSH_OPTS[@]}" "root@$ip" "bash -c \"\$(printf %s $b | base64 -d)\" box-move$q"
}

bm_idle_exempt() {
  local src
  src=$(jq -r --arg a "$1" '
    if .apps[$a] then .apps[$a].source
    else [.prefixes | to_entries[] | .key as $k | select($k != "" and ($a | startswith($k)))]
         | sort_by(.key | length) | last | .value.source // "metrics" end' "$2" 2>/dev/null)
  [ "$src" = exempt ]
}
