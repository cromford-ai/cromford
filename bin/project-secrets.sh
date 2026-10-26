#!/bin/bash
# bin/project-secrets.sh — BH-8317 (MKF-2): the Fly-secret store for a project's
# build secrets. Fly app secrets hold the values (the hub can set them and never
# read them back); the jobs worker holds only the NAMES (project_secret_names,
# GET/PUT/DELETE /api/project-secrets/names). Run on the hub, by an operator.
#
#   bin/project-secrets.sh set <project> <NAME> [--apps a,b] [--need required|optional]   < value
#   bin/project-secrets.sh unset <project> <NAME>
#   bin/project-secrets.sh list <project>
#   bin/project-secrets.sh verify <project>
#   bin/project-secrets.sh import <project>
#
# set     reads ONE value from stdin and stages it (`fly secrets import --stage`)
#         into every app of the manifest row: the row's apps, else --apps, else
#         the pool app. Order: PUT the row (no stamp), stage into each app, read
#         each digest back, PUT again with stamp:true. A failure leaves set_at
#         as it was, so `verify` and `list` show the gap.
# unset   `fly secrets unset --stage` on every manifest app ("not found" counts
#         as done), then DELETE the row (the worker writes one audit row).
# list    the manifest rows, names only: TSV name, apps, need, set_at, set_by;
#         then pending=<n> and truncated=<bool>. No Fly call.
# verify  one `fly secrets list` per distinct app. Prints MISSING <app> <staged>
#         for a required name an app lacks, OPTIONAL-MISSING for an optional
#         one, UNKNOWN <app> for a list it could not read, INCOMPLETE for a
#         truncated manifest. rc 0 only with rows, a complete list, every app
#         read and no required name missing; then `verify/<p>: ok (...)`.
# import  adopts the HBUNDLE_P_<NAME> secrets already on the pool app (put there
#         once by the ssh-mode bin/fly-pool-secrets-sync.sh <p>) as manifest
#         rows. Names and digests only; an existing row is kept as it is.
#
# THE VALUE goes only to flyctl's stdin, through the printf builtin: never on an
# argv, stdout, stderr, a log, an alert or the worker. It must be one line, not
# empty, with no single quote (dotenv import cannot carry one). A value of only
# [A-Za-z0-9_./:@+,=-] is written as is, any other in single quotes (the
# quoting rule of bin/fly-pool-secrets-sync.sh). A refusal names the key only.
# STAGED NAME: HBUNDLE_P_<NAME> on the pool app (state/fly/<p>.json .app), which
# fly/entrypoint.sh turns back into <NAME> in <project>.env; the plain <NAME> on
# any other app.
# NAME: ^[A-Z_][A-Z0-9_]{0,127}$, not GH_TOKEN, not GH_TOKEN_INSTALLATION_ID, no
# HBUNDLE_, SEED_ or FLY_ prefix (the worker's checkSecretName is the same rule).
# Each flyctl call is bounded by the settings row project_secrets.fly_timeout_s.
#
# Exit: 0 ok, 1 failure (one stderr line; an operational failure also writes one
# ALERTS line naming the project, the NAME and the app), 2 usage. The temp dir
# is removed on every exit. Note: docs/notes/2026-10-25-BH-8317-secret-store.md.
set -uo pipefail

HARNESS="${HARNESS:-/root/harness}"
usage() { sed -n '7,11p' "${BASH_SOURCE[0]}" | sed 's/^#   //' >&2; exit 2; }

VERB="${1:-}"; P="${2:-}"; NAME=""; APPS_IN=""; NEED_IN=""
case "$VERB" in set|unset|list|verify|import) ;; *) usage ;; esac
[[ "$P" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || usage

name_ok() { # R1
  [[ "$1" =~ ^[A-Z_][A-Z0-9_]{0,127}$ ]] || return 1
  case "$1" in GH_TOKEN|GH_TOKEN_INSTALLATION_ID|HBUNDLE_*|SEED_*|FLY_*) return 1 ;; esac
  return 0
}
app_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; }

case "$VERB" in
  set|unset)
    NAME="${3:-}"; name_ok "$NAME" || usage
    shift 3
    while [ $# -gt 0 ]; do
      [ "$VERB" = set ] || usage
      case "$1" in
        --apps) [ $# -ge 2 ] || usage; APPS_IN="$2"; shift 2 ;;
        --need) [ $# -ge 2 ] || usage; NEED_IN="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    if [ -n "$APPS_IN" ]; then
      IFS=, read -r -a _apps <<<"$APPS_IN"
      [ "${#_apps[@]}" -gt 0 ] || usage
      for a in "${_apps[@]}"; do app_ok "$a" || usage; done
    fi
    case "$NEED_IN" in ''|required|optional) ;; *) usage ;; esac ;;
  *) [ $# -le 2 ] || usage ;;
esac

CUR_APP=""
fail() { # fail <step> <why> — one stderr line, one ALERTS line, rc 1. Never a value.
  echo "project-secrets/$P FATAL: $1: $2" >&2
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[project-secrets/$P] $VERB${NAME:+ of $NAME}${CUR_APP:+ on $CUR_APP} FAILED at $1: $2. Check bin/project-secrets.sh verify $P." >/dev/null 2>&1 || true
  exit 1
}
# refuse <why> — an operator input the store cannot take: stderr only, rc 1.
refuse() { echo "project-secrets/$P: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || refuse "jq required"

# The jobs worker. Not fail-open here: a non-2xx is a failure. fail() is the
# alert, so the client's own outage line is off.
# shellcheck source=bin/jobs-client.sh
. "$HARNESS/bin/jobs-client.sh" 2>/dev/null || fail "jobs client" "bin/jobs-client.sh did not load"
export JOBS_ALERT=0
[ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || fail "jobs worker" "JOBS_URL or HARNESS_SECRET is not set"
api() { _jobs_req "$@"; } # api <method> <path> [body]: body on 2xx (rc 0), rc 2 on 404, else 1/9

# Fly: the pool app, the token (resolved as bin/fly-pool.sh resolves it) and
# flyctl (bin/lib/fly-bin.sh). Only the verbs that call Fly set it up.
APP=""; FLY=""; TO=120
fly_setup() {
  APP=$(jq -r '.app // ""' "$HARNESS/state/fly/$P.json" 2>/dev/null)
  [ -n "$APP" ] || fail "app lookup" "no .app in state/fly/$P.json"
  . "$HARNESS/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
  local henv tv
  henv=$(harness_env_dir "$HARNESS")
  set -a; . "$henv/fly.env" 2>/dev/null; set +a
  tv="FLY_API_TOKEN_$(echo "$P" | tr '[:lower:].-' '[:upper:]__')"
  # shellcheck source=bin/lib/fly-token.sh
  . "$HARNESS/bin/lib/fly-token.sh" 2>/dev/null || true
  if command -v fly_token_resolve >/dev/null 2>&1; then fly_token_resolve "$P"; else FLY_TOKEN_VAL="${!tv:-}"; fi
  export FLY_ACCESS_TOKEN="${FLY_TOKEN_VAL:-}"
  [ -n "$FLY_ACCESS_TOKEN" ] || fail "fly token" "neither $tv nor FLY_API_TOKEN is set"
  # shellcheck source=bin/lib/fly-bin.sh
  . "$HARNESS/bin/lib/fly-bin.sh" 2>/dev/null || fail "flyctl" "bin/lib/fly-bin.sh did not load"
  FLY=$(fly_bin) || fail "flyctl" "no flyctl on PATH, in FLY_BIN_DIR or in the install dirs"
  # Fallback 120 of the settings row project_secrets.fly_timeout_s (schema.d
  # 202610260157-bh-8317-project-secret-names.sql). A failed read uses it too.
  local v; v=$(setting_get project_secrets.fly_timeout_s 2>/dev/null) || v=""
  v="${v//[[:space:]]/}"
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 3600 ]; then TO="$v"; else TO=120; fi
}
staged_name() { if [ "$1" = "$APP" ]; then printf 'HBUNDLE_P_%s' "$2"; else printf '%s' "$2"; fi; } # R2
# fly_names <app>: the secret names on the app, one per line, into $TMP/names.<app>.
# rc 1 when the list fails or is not a JSON array.
fly_names() {
  timeout "$TO" "$FLY" secrets list -a "$1" --json > "$TMP/list.$1" 2>/dev/null || return 1
  jq -e 'type == "array"' "$TMP/list.$1" >/dev/null 2>&1 || return 1
  jq -r '.[] | (.Name // .name // empty)' "$TMP/list.$1" > "$TMP/names.$1"
}
fly_digest() { jq -r --arg s "$2" 'first(.[] | select((.Name // .name) == $s) | (.Digest // .digest // "")) // ""' "$TMP/list.$1"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/psec.XXXXXX") || fail "mktemp" "no temp dir"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

# manifest_read: the GET answer into $TMP/rows. rc 1 on any failure.
manifest_read() {
  api GET "/api/project-secrets/names?project=$P" > "$TMP/rows" || return 1
  jq -e '(.names | type) == "array"' "$TMP/rows" >/dev/null 2>&1
}
row_of() { jq -c --arg n "$1" 'first(.names[] | select(.name == $n)) // empty' "$TMP/rows"; }
truncated() { jq -e '.truncated == true' "$TMP/rows" >/dev/null 2>&1; }
ACTOR="${SUDO_USER:-${USER:-root}}@${HOSTNAME:-hub}"
ACTOR="${ACTOR//[^A-Za-z0-9._@:+-]/_}"; ACTOR="${ACTOR:0:128}"

case "$VERB" in
  set)
    fly_setup
    [ -t 0 ] && printf 'value for %s (not echoed): ' "$NAME" >&2
    v=""; IFS= read -r -s v; [ -t 0 ] && echo >&2
    while IFS= read -r extra || [ -n "$extra" ]; do
      [ -z "$extra" ] || refuse "value for $NAME has more than one line; send one line"
    done
    [ -n "$v" ] || refuse "value for $NAME is empty"
    case "$v" in *"'"*) refuse "value for $NAME has a single quote, which dotenv import cannot carry" ;; esac
    if [[ "$v" =~ ^[A-Za-z0-9_./:@+,=-]+$ ]]; then quoted="$v"; else quoted="'$v'"; fi
    unset v

    manifest_read || fail "manifest read" "GET /api/project-secrets/names did not answer"
    ROW=$(row_of "$NAME")
    [ -n "$ROW" ] || ! truncated || fail "manifest read" "the manifest list is truncated and has no row for the name; raise project_secrets.list_limit"
    if [ -n "$APPS_IN" ]; then APPS_JSON=$(jq -cn --arg a "$APPS_IN" '$a | split(",") | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end)')
    elif [ -n "$ROW" ]; then APPS_JSON=$(jq -c '.apps' <<<"$ROW")
    else APPS_JSON=$(jq -cn --arg a "$APP" '[$a]'); fi
    NEED="$NEED_IN"
    [ -n "$NEED" ] || { [ -n "$ROW" ] && NEED=$(jq -r '.need // "required"' <<<"$ROW"); }
    [ -n "$NEED" ] || NEED=required
    BODY=$(jq -cn --arg p "$P" --arg n "$NAME" --argjson a "$APPS_JSON" --arg need "$NEED" --arg by "$ACTOR" \
      '{project:$p, name:$n, apps:$a, need:$need, set_by:$by}')
    api PUT /api/project-secrets/names "$BODY" >/dev/null || fail "manifest write" "PUT /api/project-secrets/names did not answer 2xx; nothing staged"

    mapfile -t APPS < <(jq -r '.[]' <<<"$APPS_JSON")
    for CUR_APP in "${APPS[@]}"; do
      staged=$(staged_name "$CUR_APP" "$NAME")
      # printf is a builtin: the value is in no process argv.
      printf '%s=%s\n' "$staged" "$quoted" | timeout "$TO" "$FLY" secrets import --stage -a "$CUR_APP" >/dev/null 2>&1 \
        || fail "secrets import" "fly secrets import exited non-zero; the row stays pending"
    done
    unset quoted
    DIGEST='{}'
    for CUR_APP in "${APPS[@]}"; do
      staged=$(staged_name "$CUR_APP" "$NAME")
      fly_names "$CUR_APP" || fail "read back" "fly secrets list did not answer; the row stays pending"
      grep -qxF "$staged" "$TMP/names.$CUR_APP" || fail "read back" "the app does not list $staged after the import; the row stays pending"
      DIGEST=$(jq -c --arg a "$CUR_APP" --arg d "$(fly_digest "$CUR_APP" "$staged")" '. + {($a): $d}' <<<"$DIGEST")
    done
    CUR_APP=""
    BODY=$(jq -c --argjson d "$DIGEST" '. + {digest:$d, stamp:true}' <<<"$BODY")
    api PUT /api/project-secrets/names "$BODY" >/dev/null || fail "manifest stamp" "the value is staged, but the stamp PUT did not answer 2xx; the row stays pending"
    echo "project-secrets/$P: $NAME staged on ${#APPS[@]} app(s): $(IFS=,; echo "${APPS[*]}")"
    ;;

  unset)
    fly_setup
    manifest_read || fail "manifest read" "GET /api/project-secrets/names did not answer"
    ROW=$(row_of "$NAME")
    if [ -z "$ROW" ]; then
      truncated && fail "manifest read" "the manifest list is truncated and has no row for the name; raise project_secrets.list_limit"
      refuse "no manifest row for $NAME"
    fi
    mapfile -t APPS < <(jq -r '.apps[]' <<<"$ROW")
    for CUR_APP in "${APPS[@]}"; do
      staged=$(staged_name "$CUR_APP" "$NAME")
      if ! timeout "$TO" "$FLY" secrets unset --stage -a "$CUR_APP" "$staged" >/dev/null 2>"$TMP/err"; then
        grep -qiE 'not found|does not exist|no such secret' "$TMP/err" \
          || fail "secrets unset" "fly secrets unset exited non-zero; the row is kept"
      fi
    done
    CUR_APP=""
    api DELETE "/api/project-secrets/names?project=$P&name=$NAME&actor=$ACTOR" >/dev/null \
      || fail "manifest delete" "the secret is unset on every app, but DELETE /api/project-secrets/names did not answer 2xx"
    echo "project-secrets/$P: $NAME unset on ${#APPS[@]} app(s): $(IFS=,; echo "${APPS[*]}"); manifest row deleted"
    ;;

  list)
    manifest_read || fail "manifest read" "GET /api/project-secrets/names did not answer"
    printf 'name\tapps\tneed\tset_at\tset_by\n'
    jq -r '.names[] | [.name, (.apps | join(",")), .need, (.set_at // "-"), .set_by] | @tsv' "$TMP/rows"
    echo "pending=$(jq -r '.pending // 0' "$TMP/rows")"
    echo "truncated=$(jq -r '.truncated == true' "$TMP/rows")"
    ;;

  verify)
    manifest_read || fail "manifest read" "GET /api/project-secrets/names did not answer"
    truncated && { echo "INCOMPLETE: the manifest for $P is truncated; raise project_secrets.list_limit"; exit 1; }
    N=$(jq '.names | length' "$TMP/rows")
    [ "$N" -gt 0 ] || { echo "no manifest rows for $P"; exit 1; }
    fly_setup
    RC=0; UNREAD=" "
    mapfile -t ALL_APPS < <(jq -r '[.names[].apps[]] | unique | .[]' "$TMP/rows")
    for a in "${ALL_APPS[@]}"; do
      fly_names "$a" || { echo "UNKNOWN $a"; RC=1; UNREAD="$UNREAD$a "; }
    done
    while IFS=$'\t' read -r n need a; do
      case "$UNREAD" in *" $a "*) continue ;; esac
      staged=$(staged_name "$a" "$n")
      grep -qxF "$staged" "$TMP/names.$a" && continue
      if [ "$need" = optional ]; then echo "OPTIONAL-MISSING $a $staged"; else echo "MISSING $a $staged"; RC=1; fi
    done < <(jq -r '.names[] | .name as $n | .need as $need | .apps[] | [$n, $need, .] | @tsv' "$TMP/rows")
    [ "$RC" = 0 ] && echo "verify/$P: ok ($N names, ${#ALL_APPS[@]} apps)"
    exit "$RC"
    ;;

  import)
    fly_setup
    manifest_read || fail "manifest read" "GET /api/project-secrets/names did not answer"
    truncated && fail "manifest read" "the manifest list is truncated; raise project_secrets.list_limit"
    CUR_APP="$APP"
    fly_names "$APP" || fail "secrets list" "fly secrets list did not answer"
    CUR_APP=""
    IMPORTED=0; KEPT=0; SKIPPED=0
    while IFS= read -r s; do
      n="${s#HBUNDLE_P_}"
      if ! name_ok "$n"; then SKIPPED=$((SKIPPED+1)); continue; fi
      if [ -n "$(row_of "$n")" ]; then KEPT=$((KEPT+1)); continue; fi
      BODY=$(jq -cn --arg p "$P" --arg n "$n" --arg a "$APP" --arg d "$(fly_digest "$APP" "$s")" \
        '{project:$p, name:$n, apps:[$a], need:"required", set_by:"import", digest:{($a):$d}, stamp:true}')
      NAME="$n"
      api PUT /api/project-secrets/names "$BODY" >/dev/null || fail "manifest write" "PUT /api/project-secrets/names did not answer 2xx"
      NAME=""
      IMPORTED=$((IMPORTED+1))
    done < <(grep '^HBUNDLE_P_' "$TMP/names.$APP")
    echo "imported=$IMPORTED kept=$KEPT skipped=$SKIPPED"
    ;;
esac
exit 0
