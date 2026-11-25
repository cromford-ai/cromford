#!/bin/bash
# bin/lib/signal-source.sh — the per-project Sentry and PostHog sources
# (BH-9799). Sourced, never executed; set -u safe; defines functions only.
#
# THE REGISTRY. One JSON file per fleet project, catalog/signal-sources.d/<project>.json:
#   {"project": "<project>",
#    "sentry":  {"org": "<org>", "project": "<slug>", "token_env": "<ENV NAME>"},
#    "posthog": {"host": "https://<host>", "project_id": "<digits>",
#                "key_env": "<ENV NAME>", "filter": "properties.<p> = '<v>'"}}
# Each block is optional. The file holds env NAMES only, never a value. A
# project with no file (or no block of a kind) keeps today's global values.
#
#   ss_dir                    the registry directory. SIGNAL_SOURCES_DIR wins only
#                             with HARNESS_TEST_SANDBOX=1 (the test seam). rc 1 = no root.
#   ss_env_value <file> <NAME>
#                             the value of the last `[export ]NAME=` line of the
#                             file. One pair of matching outer quotes is dropped.
#                             The file is parsed, never sourced: no eval, no
#                             expansion. rc 1 = no such line (or an unreadable file).
#   ss_token <project> <NAME> ${!NAME} when set and not empty, else NAME from
#                             <env-dir>/<project>.env (bin/lib/env-path.sh),
#                             else empty. Always rc 0. The ONE place a token is
#                             resolved.
#   ss_sentry <project>       rc 0: SS_ORG, SS_SLUG, SS_TOKEN_ENV, SS_TOKEN set
#                             (SS_TOKEN may be empty). rc 3: no row, or no sentry
#                             block. rc 1: the row fails validation (one stderr
#                             line that names the field, never a value).
#   ss_posthog <project>      the same rc rules; SS_HOST, SS_PID, SS_KEY_ENV,
#                             SS_KEY, SS_FILTER (may be empty).
#   ss_projects <kind>        sentry|posthog: the project of each valid row with
#                             that block, in file-name order, one per line.
#
# VALIDATION. project ^[a-z0-9-]+$ and equal to the file name (a copied row
# must never send one project's token to another org); org and slug
# ^[a-z0-9_-]+$; env names ^[A-Z][A-Z0-9_]{0,63}$; host ^https://[a-z0-9.-]+$;
# project_id ^[0-9]+$; filter empty or ^properties\.[A-Za-z0-9_$]+ = '[A-Za-z0-9._-]+'$.

[ "$(type -t harness_env_dir)" = function ] || . "${BASH_SOURCE[0]%/*}/env-path.sh" 2>/dev/null

ss_dir() {
  local r="${HARNESS:-${H:-}}"
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${SIGNAL_SOURCES_DIR:-}" ]; then
    printf '%s' "$SIGNAL_SOURCES_DIR"; return 0
  fi
  [ -n "$r" ] || return 1
  printf '%s/catalog/signal-sources.d' "$r"
}

ss_env_value() {
  local f=${1:-} n=${2:-} line v
  [[ $n =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || return 1
  [ -r "$f" ] || return 1
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?$n=" "$f" 2>/dev/null | tail -n 1)
  [ -n "$line" ] || return 1
  v=${line#*"$n"=}
  v=${v%$'\r'}
  if [[ $v =~ ^\"(.*)\"[[:space:]]*$ ]] || [[ $v =~ ^\'(.*)\'[[:space:]]*$ ]]; then v=${BASH_REMATCH[1]}
  else v=${v%%[[:space:]]#*}; v=${v%"${v##*[![:space:]]}"}; fi
  printf '%s' "$v"
}

ss_token() {
  local p=${1:-} n=${2:-} r d v=""
  [[ $n =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || return 0
  if [ -n "${!n:-}" ]; then printf '%s' "${!n}"; return 0; fi
  [[ $p =~ ^[a-z0-9-]+$ ]] || return 0
  r="${HARNESS:-${H:-}}"
  [ -n "$r" ] || return 0
  command -v harness_env_dir >/dev/null 2>&1 || return 0
  d=$(harness_env_dir "$r") || return 0
  v=$(ss_env_value "$d/$p.env" "$n") || v=""
  printf '%s' "$v"
}

_SS_FILTER_RE="^properties\\.[A-Za-z0-9_\$]+ = '[A-Za-z0-9._-]+'\$"

# _ss_bad <project> <field>: the one stderr line of an invalid row.
_ss_bad() { printf 'signal-source: %s.json: bad or missing %s; the row is not used\n' "$1" "$2" >&2; return 1; }

# _ss_load <project> <kind>: validate the row and set the fields of that kind.
_ss_load() {
  local p=${1:-} k=${2:-} dir f j a b c e
  [[ $p =~ ^[a-z0-9-]+$ ]] || return 3
  dir=$(ss_dir) || return 3
  f="$dir/$p.json"
  [ -f "$f" ] || return 3
  j=$(jq -c 'if type == "object" then . else error("not an object") end' "$f" 2>/dev/null) || { _ss_bad "$p" json; return 1; }
  [ "$(jq -r '.project // "" | tostring' <<<"$j")" = "$p" ] || { _ss_bad "$p" project; return 1; }
  jq -e --arg k "$k" '.[$k] | type == "object"' <<<"$j" >/dev/null 2>&1 || return 3
  case "$k" in
    sentry)
      { IFS=$'\t' read -r a b c; } < <(jq -r '.sentry | [(.org // "" | tostring), (.project // "" | tostring), (.token_env // "" | tostring)] | @tsv' <<<"$j")
      [[ $a =~ ^[a-z0-9_-]+$ ]] || { _ss_bad "$p" sentry.org; return 1; }
      [[ $b =~ ^[a-z0-9_-]+$ ]] || { _ss_bad "$p" sentry.project; return 1; }
      [[ $c =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || { _ss_bad "$p" sentry.token_env; return 1; }
      SS_ORG=$a; SS_SLUG=$b; SS_TOKEN_ENV=$c ;;
    posthog)
      { IFS=$'\t' read -r a b c; } < <(jq -r '.posthog | [(.host // "" | tostring), (.project_id // "" | tostring), (.key_env // "" | tostring)] | @tsv' <<<"$j")
      e=$(jq -r '.posthog.filter // "" | tostring' <<<"$j")
      [[ $a =~ ^https://[a-z0-9.-]+$ ]] || { _ss_bad "$p" posthog.host; return 1; }
      [[ $b =~ ^[0-9]+$ ]] || { _ss_bad "$p" posthog.project_id; return 1; }
      [[ $c =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || { _ss_bad "$p" posthog.key_env; return 1; }
      [ -z "$e" ] || [[ $e =~ $_SS_FILTER_RE ]] || { _ss_bad "$p" posthog.filter; return 1; }
      SS_HOST=$a; SS_PID=$b; SS_KEY_ENV=$c; SS_FILTER=$e ;;
    *) return 3 ;;
  esac
  return 0
}

ss_sentry() {
  local rc=0
  SS_ORG=""; SS_SLUG=""; SS_TOKEN_ENV=""; SS_TOKEN=""
  _ss_load "${1:-}" sentry || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  SS_TOKEN=$(ss_token "$1" "$SS_TOKEN_ENV")
  return 0
}

ss_posthog() {
  local rc=0
  SS_HOST=""; SS_PID=""; SS_KEY_ENV=""; SS_KEY=""; SS_FILTER=""
  _ss_load "${1:-}" posthog || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  SS_KEY=$(ss_token "$1" "$SS_KEY_ENV")
  return 0
}

ss_projects() {
  local k=${1:-} dir f p
  case "$k" in sentry|posthog) ;; *) return 1 ;; esac
  dir=$(ss_dir) || return 0
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    p=$(basename "$f" .json)
    ( _ss_load "$p" "$k" ) && printf '%s\n' "$p"
  done
  return 0
}
