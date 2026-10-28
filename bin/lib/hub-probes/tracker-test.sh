#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/tracker-test.sh — BH-7936: the hub probe behind the
# onboarding tracker sheets' "Test and connect". Sourced by common.sh's hp_run.
#
# hp_probe_tracker_test <linear|jira|board> <envelope uuid>
#   1. onb_open <uuid> <row file>: the secret envelope the console stored
#      (BH-7968; scope tracker:<kind>:<project>, plaintext {"fields":{...}}
#      sealed to the hub key). ONE GET /api/secrets/envelope/<uuid> with the
#      hub token (bin/lib/envelope.sh envelope_req); the read deletes the
#      envelope, so the credential is gone from the worker before any vendor
#      call. envelope_decrypt opens it with the hub key (ENVELOPE_KEY, default
#      /etc/harness/envelope.key, and its rotated keys inside the TTL).
#   2. The scope must be tracker:<kind>:<project> with <kind> the probe's own
#      arg; anything else (an ai-account envelope above all) is
#      `FAIL scope refused`, and nothing is called.
#   3. _onb_fields_check: the BH-7936 field table (the same table as
#      console-ui/src/lib/tracker-sheets.js checkTrackerFields). Only the hub
#      sees the fields, so this is where a private board host, a short secret
#      or a foreign Jira site is refused, before any vendor call.
#   4. onb_tracker_check: one read and one dry write through bin/lib/tracker.sh
#      with the fields as the adapter context, in a subshell.
#   PASS (rc 0, HP_HTTP_STATUS=200): `ok list=<n> dry-write=ok`, or
#   `ok list=0 dry-write=skipped` and a line saying why when the list is empty.
#   FAIL (rc 1, HP_HTTP_STATUS=000): `FAIL <what>` and the adapter's stderr,
#   first 20 lines. The envelope FAIL lines are: `credential expired, test
#   again` (404), `hub token not accepted` (401/403), `credential store not
#   configured` (no JOBS_URL, HARNESS_SECRET or ENVELOPE_HUB_TOKEN, or 503),
#   `credential store unreachable, test again`, `decrypt failed`,
#   `scope refused ...`, `credential is not readable`.
#   Every output line is scrubbed: each secret field value (api_key,
#   api_token, token) and the email, of 4 characters or more, is replaced by
#   `[redacted]`. The output is what the hub-probe ledger stores and what the
#   sheet shows. The opened row lives only in a mode-600 temp file, removed
#   before the function returns. No line holds a ciphertext or a field value.
#
# onb_open <uuid> <row file> — steps 1 and 2 without the kind check: writes
#   {kind, project, fields} to the row file, rc 0; else one FAIL line, rc 1.
# onb_tracker_check <kind> <row file> — the read + dry write, as above, without
#   the open or the scrub. The onboarding `tracker` station (wave 1's
#   bin/lib/onboard-stations.sh) is meant to call this same function.
command -v _jobs_req >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../../jobs-client.sh" >/dev/null 2>&1
# shellcheck source=bin/lib/envelope.sh
declare -F envelope_decrypt >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../envelope.sh"

ONB_SECRET_FIELDS="api_key api_token token email"

onb_open() {
  local id="${1:-}" f="${2:-}" tmp code rc=0 scope ct plain kind project
  [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "FAIL credential id is not an envelope id"; return 1; }
  [ -n "$f" ] || { echo "FAIL no row file"; return 1; }
  declare -F envelope_req >/dev/null 2>&1 && declare -F envelope_decrypt >/dev/null 2>&1 \
    || { echo "FAIL credential store not configured (bin/lib/envelope.sh missing)"; return 1; }
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/onb-trk-env.XXXXXX") || { echo "FAIL no temp file"; return 1; }
  code=$(envelope_req GET "/api/secrets/envelope/$id" "$tmp") || rc=$?
  scope=$(jq -r '.scope // empty | strings' "$tmp" 2>/dev/null)
  ct=$(jq -r '.ciphertext // empty | strings' "$tmp" 2>/dev/null)
  rm -f "$tmp"
  if [ "$rc" = 1 ]; then echo "FAIL credential store not configured"; return 1; fi
  case "$code" in
    200) ;;
    404) echo "FAIL credential expired, test again"; return 1 ;;
    401|403) echo "FAIL hub token not accepted"; return 1 ;;
    503) echo "FAIL credential store not configured"; return 1 ;;
    *) echo "FAIL credential store unreachable (http $code), test again"; return 1 ;;
  esac
  if [[ "$scope" =~ ^tracker:(linear|jira|board):([a-z0-9._@-]{1,64})$ ]] && [[ "$scope" != *..* ]]; then
    kind="${BASH_REMATCH[1]}"; project="${BASH_REMATCH[2]}"
  else
    echo "FAIL scope refused (not a tracker credential)"; return 1
  fi
  plain=$(printf '%s' "$ct" | envelope_decrypt "${ENVELOPE_KEY:-/etc/harness/envelope.key}") || { ct=""; echo "FAIL decrypt failed"; return 1; }
  ct=""
  # The plaintext goes to jq on stdin, never on argv.
  if ! printf '%s' "$plain" | (umask 077; jq -ce --arg k "$kind" --arg p "$project" \
      'select(type == "object" and (.fields | type == "object") and ([.fields[] | type == "string"] | all))
       | {kind: $k, project: $p, fields: .fields}' > "$f" 2>/dev/null); then
    plain=""; : > "$f"; echo "FAIL credential is not readable"; return 1
  fi
  plain=""
  return 0
}

# _onb_fields_check <row file> — the BH-7936 field table over .fields: each
# value trimmed, the Jira site lower-cased, then checked. Rewrites the row
# file with the checked fields, rc 0; else one `FAIL <reason>` line, rc 1.
# The reason never holds a value.
ONB_FIELDS_JQ='
def spec: {
  linear: [["api_key","secret"],["team","team"],["label","label"]],
  jira: [["site","site"],["email","email"],["api_token","secret"],["project_key","jira_key"],["status_map","status_map"]],
  board: [["api_base","api_base"],["token","secret"]]
};
def dotted4: test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$");
def private4: (split(".") | map(tonumber)) as $o | $o[0] as $a | $o[1] as $b
  | ($a == 0 or $a == 10 or $a == 127 or ($a == 169 and $b == 254) or ($a == 172 and $b >= 16 and $b <= 31)
     or ($a == 192 and $b == 168) or ($a == 100 and $b >= 64 and $b <= 127) or $a >= 224);
def base_err:
  if test("^https://"; "i") | not then "api_base must be an https:// URL"
  else (sub("^https://"; ""; "i") | capture("^(?<auth>[^/?#]*)(?<rest>.*)$")) as $u
  | if ($u.auth | test("@")) or ($u.rest | test("[?#]")) then "api_base must not carry a user, a query or a fragment"
    else ($u.auth | ascii_downcase | sub(":[0-9]*$"; "")) as $h
    | if ($h | test("^[a-z0-9_.-]+$") | not) or $h == "localhost" or ($h | endswith(".localhost")) or ($h | contains(".") | not)
         or (if ($h | dotted4) then ($h | private4) else (($h | split(".") | last | test("^[0-9]+$")) or ($h | test("(^|\\.)0x"))) end)
      then "api_base must be a public host" else null end
    end
  end;
def ferr($n; $t; $v):
  if $t == "secret" then (if ($v | length) >= 8 then null else "\($n) must be at least 8 characters" end)
  elif $t == "team" then (if $v | test("^[A-Za-z0-9_]{1,16}$") then null else "team must be a Linear team key (letters, digits, _)" end)
  elif $t == "label" then (if $v | test("^[^\\s\"\\\\][^\"\\\\]{0,99}$") then null else "label must be 1-100 characters with no quote or backslash" end)
  elif $t == "site" then (if $v | test("^[a-z0-9-]+\\.atlassian\\.net$") then null else "site must be <name>.atlassian.net" end)
  elif $t == "email" then (if $v | test("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$") then null else "email must be an email address" end)
  elif $t == "jira_key" then (if $v | test("^[A-Z][A-Z0-9_]{1,9}$") then null else "project_key must be a Jira project key (CROM)" end)
  elif $t == "status_map" then (if $v | split(";") | all(test("^[a-z0-9_-]+=[^=;]+$")) then null else "status_map must be alias=Status;alias=Status" end)
  elif $t == "api_base" then ($v | base_err)
  else "\($n) is not a field" end;
. as $row | spec[$row.kind] as $spec | $row.fields as $f
| if $spec == null then {error: "kind must be linear, jira or board"}
  else ([$f | keys_unsorted[] | select(. as $x | ($spec | map(.[0]) | index($x)) == null)] | first) as $extra
  | if $extra != null then {error: "\($extra) is not a \($row.kind) field"}
    else reduce $spec[] as $s ({fields: {}};
      if .error then . else
        $s[0] as $n | $s[1] as $t | $f[$n] as $v0
        | if $v0 == null then {error: "\($n) is required"}
          elif ($v0 | type) != "string" then {error: "\($n) must be a string"}
          else ($v0 | sub("^\\s+"; "") | sub("\\s+$"; "")) as $v1
          | if $v1 == "" then {error: "\($n) is required"}
            elif ($v1 | length) > 512 then {error: "\($n) must be at most 512 characters"}
            else (if $t == "site" then ($v1 | ascii_downcase) else $v1 end) as $v
            | ferr($n; $t; $v) as $e
            | if $e then {error: $e} else .fields[$n] = $v end
            end
          end
      end)
    end
  end
| if .error then {error} else $row + {fields: .fields} end'

_onb_fields_check() {
  local f="$1" out err
  out=$(umask 077; mktemp "${TMPDIR:-/tmp}/onb-trk-chk.XXXXXX") || { echo "FAIL no temp file"; return 1; }
  if ! jq -c "$ONB_FIELDS_JQ" "$f" > "$out" 2>/dev/null; then rm -f "$out"; echo "FAIL the credential fields could not be checked"; return 1; fi
  err=$(jq -r '.error // empty' "$out" 2>/dev/null)
  if [ -n "$err" ]; then rm -f "$out"; echo "FAIL $err"; return 1; fi
  mv -f "$out" "$f"
}

_onb_field() { jq -r --arg k "$1" '.fields[$k] // empty | strings' "$2" 2>/dev/null; }
_onb_errtail() { [ -s "$1" ] && head -n 20 "$1"; return 0; }

onb_tracker_check() {
  local kind="${1:-}" f="${2:-}" lib err body rc=0
  [ -r "$f" ] || { echo "FAIL no credential row"; return 1; }
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || { echo "FAIL no bin/lib"; return 1; }
  err=$(mktemp "${TMPDIR:-/tmp}/onb-trk-err.XXXXXX") || { echo "FAIL no temp file"; return 1; }
  body=$(mktemp "${TMPDIR:-/tmp}/onb-trk-body.XXXXXX") || { rm -f "$err"; echo "FAIL no temp file"; return 1; }
  (
    TRK_LOG=""; TRK_REQ_FILE=""; TRK_ERR="$err"; TRK_DRY=0
    # shellcheck source=bin/lib/tracker.sh
    . "$lib/tracker.sh" || { echo "FAIL tracker library missing"; exit 1; }
    tracker_load "$kind" || { echo "FAIL no $kind adapter"; exit 1; }
    case "$kind" in
      linear)
        TRK_LINEAR_TOKEN=$(_onb_field api_key "$f"); TRK_LINEAR_TOKEN_VAR=LINEAR_API_KEY
        TRK_LINEAR_TEAM=$(_onb_field team "$f"); TRK_LINEAR_LABEL=$(_onb_field label "$f") ;;
      jira)
        r=0
        trk_jira_context_fields "$(_onb_field site "$f")" "$(_onb_field email "$f")" "$(_onb_field api_token "$f")" \
          "$(_onb_field project_key "$f")" "$(_onb_field status_map "$f")" 2>>"$err" || r=$?
        if [ "$r" != 0 ]; then echo "FAIL jira context (rc $r)"; _onb_errtail "$err"; exit 1; fi ;;
      board)
        TRK_BOARD_BASE=$(_onb_field api_base "$f"); TRK_BOARD_TOKEN=$(_onb_field token "$f"); TRK_BOARD_TOKEN_VAR=BOARD_TOKEN ;;
      *) echo "FAIL $kind is not linear, jira or board"; exit 1 ;;
    esac
    r=0; list=$(tracker_list 2>>"$err") || r=$?
    if [ "$r" != 0 ] || ! n=$(printf '%s' "$list" | jq -er 'if type == "array" then length else error end' 2>/dev/null); then
      echo "FAIL tracker list failed (rc $r)"
      [ "$r" = 75 ] && echo "the tracker was rate-limited or did not answer; test again in a few minutes"
      _onb_errtail "$err"; exit 1
    fi
    first=$(printf '%s' "$list" | jq -r '.[0].id // empty')
    if [ -z "$first" ]; then
      echo "ok list=0 dry-write=skipped"
      echo "no open ticket with the build label; dry write skipped"
      exit 0
    fi
    printf 'Onboarding connection test (dry run, never sent).\n' > "$body"
    r=0; dry=$(TRK_DRY=1 tracker_comment "$first" "$body" 2>>"$err") || r=$?
    if [ "$r" != 0 ] || ! grep -q '^DRYRUN ' <<<"$dry"; then
      echo "FAIL dry write on $first failed (rc $r)"; _onb_errtail "$err"; exit 1
    fi
    echo "ok list=$n dry-write=ok"
  ) || rc=$?
  rm -f "$err" "$body"
  return "$rc"
}

# _onb_probe <kind> <envelope id> <row file> — the open, the checks and the
# tracker check; unscrubbed.
_onb_probe() {
  local kind="$1" id="$2" f="$3" got
  onb_open "$id" "$f" || return 1
  got=$(jq -r '.kind' "$f" 2>/dev/null)
  [ "$got" = "$kind" ] || { echo "FAIL scope refused: the credential is for $got, not $kind"; return 1; }
  _onb_fields_check "$f" || return 1
  onb_tracker_check "$kind" "$f"
}

hp_probe_tracker_test() {
  local kind="${1:-}" id="${2:-}" f out rc=0
  HP_HTTP_STATUS=000
  f=$(umask 077; mktemp "${TMPDIR:-/tmp}/onb-trk-row.XXXXXX") || { echo "FAIL no temp file"; return 1; }
  out=$(umask 077; mktemp "${TMPDIR:-/tmp}/onb-trk-out.XXXXXX") || { rm -f "$f"; echo "FAIL no temp file"; return 1; }
  _onb_probe "$kind" "$id" "$f" > "$out" 2>&1 || rc=$?
  # The scrub: a literal split/join per secret value, so no value is a pattern.
  if ! jq -Rr --slurpfile r <(cat "$f" 2>/dev/null; echo) --arg names "$ONB_SECRET_FIELDS" '
      [(($r[0] // {}).fields // {}) | to_entries[]
        | select(.key as $k | ($names | split(" ") | index($k)) != null)
        | .value | select(type == "string" and length >= 4)] as $s
      | reduce $s[] as $x (.; split($x) | join("[redacted]"))' "$out" 2>/dev/null; then
    echo "FAIL the probe output could not be scrubbed, so it is not shown"; rc=1
  fi
  rm -f "$f" "$out"
  [ "$rc" = 0 ] && HP_HTTP_STATUS=200
  return "$rc"
}
