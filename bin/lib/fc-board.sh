#!/bin/bash
# bin/lib/fc-board.sh — the in-app board lane module of the child filer
# (bin/lib/file-children.sh). It creates one ticket per child over the board
# API, in order, carrying the parent and dependency ids, then comments on the
# master and moves it to `in_progress`. file_children sources it for any
# project whose fleet.conf column 4 is not `-` (BH-983).
#
# ITS INPUTS ARE THE FC_* VARIABLES file_children SETS, never arguments:
# FC_PROJECT, FC_PARENT (the board ticket id), FC_KEY, FC_BUILD, FC_SPEC
# (children.json, validated by the caller), FC_KIND (decompose|rollout), FC_LANE.
#
# Sourced, never executed: no `set -e`, no `exit`, no side effect at source
# time, safe under `set -u`. A failure RETURNS 1 with its reason in FC_ERROR and
# one fc_log line.
#
# WHAT IT WRITES in $FC_BUILD:
#   children.txt         one board key per filed child, append-only, written
#                        right after that child's create answered (the record
#                        bin/run-rollout.sh counts)
#   children-board.tsv   `<n>\t<key>\t<id as JSON>`, written in the same step,
#                        because a resumed child's dependents need its board id
#                        and children.txt holds keys only
#   children/            child-<n>.html and create-<n>.json, what was sent
#   decompose-board.log  every curl, with the token as its variable NAME
#
# THE CAPABILITY GATE. `GET {BASE}/boards` is read for board [0], the board the
# creates go to. `rollout` fails CLOSED: without `capabilities` containing
# "dependencies" (a real JSON list, on that board) the waves would land
# unsequenced, so it refuses before any write. `decompose` fails OPEN: its
# siblings are parallel on purpose, so it files without `parentId`/`dependsOn`
# and writes `Blocked-by: <contract key> (hard)[, <sibling key> (hard)…]` text
# from the keys the creates returned. On a capable board decompose writes the
# ids instead (BH-3965): `dependsOn` = [contract id, then the `after` sibling
# ids], and no `Blocked-by:` text line.
#
# THE TOKEN never reaches a log, a file or a body. It lives in one local and is
# handed to curl on its command line, the way bin/run-decompose.sh does.
#
# THE BOARD CALLS go through the tracker contract's board adapter
# (bin/lib/tracker/board.sh, BH-4075): every curl is its _trk_board_curl, and
# the parent read, the split comment and the move are its verbs. Beside this
# file first, $HARNESS/bin/lib second; without it nothing is filed.
if ! command -v _trk_board_curl >/dev/null 2>&1; then
  _fcb_d="$(dirname "${BASH_SOURCE[0]}")"
  if [ ! -r "$_fcb_d/tracker/board.sh" ] && [ -n "${HARNESS:-${H:-}}" ]; then _fcb_d="${HARNESS:-${H:-}}/bin/lib"; fi
  if [ -r "$_fcb_d/tracker.sh" ] && [ -r "$_fcb_d/tracker/board.sh" ]; then
    # shellcheck source=bin/lib/tracker.sh
    . "$_fcb_d/tracker.sh"
    # shellcheck source=bin/lib/tracker/board.sh
    . "$_fcb_d/tracker/board.sh"
  fi
  unset _fcb_d
fi

# _fcb_fail <msg> — set FC_ERROR, log it, return 1.
_fcb_fail() { FC_ERROR="$1"; fc_log "$FC_BUILD" "$FC_ERROR"; return 1; }

# _fcb_html — stdin text to stdout HTML: `& < >` escaped, blank-line-separated
# paragraphs become <p>, single newlines inside one become <br>. Not a markdown
# renderer: the body is shown as its author wrote it, never injected as markup.
_fcb_html() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' | awk '
    /^[ \t]*$/ { if (p != "") { print "<p>" p "</p>"; p = "" }; next }
    { p = (p == "" ? $0 : p "<br>" $0) }
    END { if (p != "") print "<p>" p "</p>" }'
}

# _fcb_curl <GET|POST> <url> [<json file> [<idempotency key>]] — one board call,
# the adapter's _trk_board_curl, with the TRK_* context fc_file_board set from
# its own locals (decompose-board.log, children/curl.err, the dry flag, the token).
_fcb_curl() { _trk_board_curl "$@"; }

# _fcb_append <file> <line> — append-only, and a record that ends without a
# newline is terminated first so the new line is not glued onto it (BH-1482).
_fcb_append() {
  [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ] && printf '\n' >> "$1"
  printf '%s\n' "$2" >> "$1"
}

# fc_file_board — files every child in FC_SPEC. 0 = filed (or a dry run),
# 1 = refused or failed, FC_ERROR says why.
fc_file_board() {
  local _FCB_DRY=0 _FCB_TOKEN="" _FCB_TOKEN_VAR="" envdir envfile
  local BASE N BOARDS BOARD_ID="" CAP=0 PARENT PRIORITY="" PARENT_ID_JSON="" RESP RC
  local i n p A P TITLE BODY CT BLOCK DEPENDS CONTRACT="" AFTERS KEEP DEPS REQ HTML
  local KEY ID URL FILED_NEW=0 WORD _ei _eln=0 tn tk tid COMMENT LI
  local EXISTING=() KEYS=() IDS=() URLS=() TITLES=()
  local TRK_LOG="" TRK_ERR="" TRK_DRY=0 TRK_BOARD_BASE="" TRK_BOARD_TOKEN="" TRK_BOARD_TOKEN_VAR="" TRK_REQ_FILE="" TRK_CURL_RC=0
  fc_dry && _FCB_DRY=1
  FC_PROJECT="${FC_PROJECT:-}"; FC_PARENT="${FC_PARENT:-}"; FC_KEY="${FC_KEY:-}"
  FC_BUILD="${FC_BUILD:-}"; FC_SPEC="${FC_SPEC:-}"; FC_KIND="${FC_KIND:-decompose}"
  FC_ERROR=""

  # A dry run cannot prove what a previous run filed, so a record means "done".
  if [ -s "$FC_BUILD/children.txt" ] && [ "$_FCB_DRY" = 1 ]; then
    fc_log "$FC_BUILD" "already filed: $(paste -sd, "$FC_BUILD/children.txt") — nothing re-filed (dry run)"
    return 0
  fi
  # THE RECORD IS READ BEFORE ANYTHING IS SENT. Every line is a board key or the
  # run stops with the file untouched: the record is the only evidence of
  # tickets that exist on the client's board (same rule as fc-issues.sh).
  if [ -s "$FC_BUILD/children.txt" ]; then
    while IFS= read -r _ei || [ -n "$_ei" ]; do
      _eln=$((_eln + 1))
      grep -qE '^[A-Za-z]+-[0-9]+$' <<<"$_ei" \
        || { _fcb_fail "children.txt line $_eln is not a board key ('$_ei') — left as it was, resolve by hand"; return 1; }
      EXISTING+=("$_ei")
    done < "$FC_BUILD/children.txt"
  fi
  N=$(jq 'length' "$FC_SPEC" 2>/dev/null)
  case "${N:-}" in ''|*[!0-9]*) _fcb_fail "cannot read a child count from $FC_SPEC"; return 1 ;; esac
  [ "${#EXISTING[@]}" -le "$N" ] \
    || { _fcb_fail "children.txt records ${#EXISTING[@]} children but the spec has $N — left as it was, resolve by hand"; return 1; }
  # The recorded ids, by position. A line whose key is not the record's key at
  # that position is not trusted.
  if [ -s "$FC_BUILD/children-board.tsv" ]; then
    while IFS=$'\t' read -r tn tk tid; do
      case "$tn" in ''|*[!0-9]*) continue ;; esac
      [ "$tk" = "${EXISTING[$((tn - 1))]:-}" ] && [ -n "$tid" ] && IDS[tn]="$tid"
    done < "$FC_BUILD/children-board.tsv"
  fi

  command -v trk_board_transition >/dev/null 2>&1 \
    || { _fcb_fail "tracker adapter bin/lib/tracker/board.sh not found beside $(dirname "${BASH_SOURCE[0]}") or in \$HARNESS/bin/lib — nothing filed"; return 1; }
  # Base from fleet.conf column 4, never a constant (docs/BOARD-API-CONTRACT.md).
  BASE=$(fc_board_base "$FC_PROJECT") && [ -n "$BASE" ] \
    || { _fcb_fail "no board base for $FC_PROJECT (fleet.conf column 4 + *_API_BASE)"; return 1; }
  # The token the way bin/run-decompose.sh reads it: the first
  # *_INTERNAL_API_TOKEN name in env/<project>.env, its exported value first,
  # then the literal. fc_board_base above already sourced env-path.sh.
  # No root = no env file (fc_board_base above has already refused).
  envdir=""; envfile=""
  if [ -z "${HARNESS:-${H:-}}" ]; then :
  elif command -v harness_env_dir >/dev/null 2>&1; then envdir=$(harness_env_dir "${HARNESS:-${H:-}}")
  else envdir="${HARNESS:-${H:-}}/env"; fi
  [ -n "$envdir" ] && envfile="$envdir/$FC_PROJECT.env"
  _FCB_TOKEN_VAR=$(grep -oE '^[A-Z_]+_INTERNAL_API_TOKEN' "$envfile" 2>/dev/null | head -1)
  if [ -n "$_FCB_TOKEN_VAR" ]; then
    _FCB_TOKEN="${!_FCB_TOKEN_VAR:-}"
    if [ -z "$_FCB_TOKEN" ]; then
      _FCB_TOKEN=$(sed -n "s/^${_FCB_TOKEN_VAR}=//p" "$envfile" 2>/dev/null | head -1)
      _FCB_TOKEN="${_FCB_TOKEN%\"}"; _FCB_TOKEN="${_FCB_TOKEN#\"}"; _FCB_TOKEN="${_FCB_TOKEN%\'}"; _FCB_TOKEN="${_FCB_TOKEN#\'}"
    fi
  fi
  [ -n "$_FCB_TOKEN" ] || [ "$_FCB_DRY" = 1 ] \
    || { _fcb_fail "no *_INTERNAL_API_TOKEN for $FC_PROJECT in $envfile — nothing filed"; return 1; }
  mkdir -p "$FC_BUILD/children"
  : > "$FC_BUILD/decompose-board.log"
  TRK_LOG="$FC_BUILD/decompose-board.log"; TRK_ERR="$FC_BUILD/children/curl.err"; TRK_DRY="$_FCB_DRY"
  TRK_BOARD_BASE="$BASE"; TRK_BOARD_TOKEN="$_FCB_TOKEN"; TRK_BOARD_TOKEN_VAR="$_FCB_TOKEN_VAR"

  # ---- capability probe --------------------------------------------------
  if [ "$_FCB_DRY" = 1 ]; then
    _fcb_curl GET "$BASE/boards"
    BOARD_ID="{boardId}"; CAP=1
    fc_log "$FC_BUILD" "capability probe NOT run (dry run) — the printed creates assume 'dependencies'"
  else
    BOARDS=$(_fcb_curl GET "$BASE/boards"); RC=$?
    if [ "$RC" = 0 ]; then
      BOARD_ID=$(printf '%s' "$BOARDS" | jq -r '(.boards? // .) | if type == "array" then (.[0].id // empty | tostring) else empty end' 2>/dev/null)
      # A LIST that holds the exact string, on board [0]. A string
      # "dependencies", null, a near-miss spelling or board [1] are all no.
      [ "$(printf '%s' "$BOARDS" | jq -r '(.boards? // .) | if type == "array" then (.[0].capabilities | if type == "array" then any(.[]; . == "dependencies") else false end) else false end' 2>/dev/null)" = true ] && CAP=1
    fi
    if [ "$FC_KIND" = rollout ] && { [ "$RC" != 0 ] || [ -z "$BOARD_ID" ] || [ "$CAP" != 1 ]; }; then
      # Unsequenced waves are worse than no waves: nothing is written.
      fc_log "$FC_BUILD" "probe GET $BASE/boards: curl rc=$RC, board '${BOARD_ID:-none}', dependencies=$CAP"
      _fcb_fail "ROLLOUT_FAILED board lacks dependencies"; return 1
    fi
    [ -n "$BOARD_ID" ] || { _fcb_fail "cannot discover a board id from GET $BASE/boards (curl rc=$RC)"; return 1; }
    [ "$CAP" = 1 ] || fc_log "$FC_BUILD" "WARN: board $BOARD_ID does not advertise 'dependencies' — filing without parentId/dependsOn"
  fi

  # ---- the parent: its priority and its id as the board types it ---------
  PARENT=""
  if [ "$_FCB_DRY" = 1 ]; then trk_board_ticket_raw "$FC_PARENT"
  else PARENT=$(trk_board_ticket_raw "$FC_PARENT") || PARENT=""; fi
  PRIORITY=$(printf '%s' "$PARENT" | jq -r '(.ticket // .) | .priority // empty | tostring' 2>/dev/null)
  PARENT_ID_JSON=$(printf '%s' "$PARENT" | jq -c '(.ticket // .) | .id // empty' 2>/dev/null)
  if [ -z "$PARENT_ID_JSON" ]; then
    [ "$_FCB_DRY" = 1 ] || fc_log "$FC_BUILD" "WARN: could not read parent $FC_PARENT — children get no inherited priority"
    case "$FC_PARENT" in ''|*[!0-9]*) PARENT_ID_JSON=$(jq -Rn --arg p "$FC_PARENT" '$p') ;; *) PARENT_ID_JSON="$FC_PARENT" ;; esac
  fi
  [ "$FC_KIND" = rollout ] \
    || CONTRACT=$(jq -r 'if ((.[0].contract? // "") | type) == "string" then (.[0].contract // "") else "" end' "$FC_SPEC" 2>/dev/null)

  # ---- the creates, in order ---------------------------------------------
  i=0
  while [ "$i" -lt "$N" ]; do
    n=$((i + 1))
    TITLE=$(jq -r --argjson i "$i" '.[$i].title' "$FC_SPEC")
    TITLES[n]="$TITLE"
    if [ -n "${EXISTING[$i]:-}" ]; then
      # Recorded by an earlier run: reused, never re-created.
      [ -n "${IDS[n]:-}" ] \
        || { _fcb_fail "cannot resolve the board id of recorded child ${EXISTING[$i]} (no children-board.tsv line) — nothing re-created, resolve by hand"; return 1; }
      KEYS[n]="${EXISTING[$i]}"; URLS[n]=""
      fc_log "$FC_BUILD" "child $n: already filed as ${KEYS[n]}"
      i=$n; continue
    fi
    BODY=$(jq -r --argjson i "$i" '.[$i].body' "$FC_SPEC")
    CT=$(fc_child_title "$FC_KIND" "$FC_KEY" "$i" "$TITLE")
    # `after` entries arrive as 2, "2" or "2:hard" and are 1-based positions.
    # Kept: earlier positions only. For a decompose sibling the contract (1) is
    # seeded below, so naming it here adds nothing; the contract itself depends
    # on nothing.
    AFTERS=$(jq -r --argjson i "$i" '(.[$i].after // []) | .[] | tostring' "$FC_SPEC" 2>/dev/null)
    KEEP=""
    if [ "$FC_KIND" != rollout ] && [ "$i" = 0 ]; then
      [ -n "$AFTERS" ] && fc_log "$FC_BUILD" "contract child: ignored 'after: $(paste -sd, <<<"$AFTERS")' — the contract waits on nothing"
    else
      while IFS= read -r A; do
        P=$(printf '%s' "${A%%:*}" | tr -d '[:space:]')
        case "$P" in ''|*[!0-9]*) continue ;; esac
        [ "$FC_KIND" != rollout ] && [ "$P" = 1 ] && continue
        if [ "$P" -lt 1 ] || [ "$P" -ge "$n" ]; then
          fc_log "$FC_BUILD" "child $n: dropped 'after: $A' — a child can only depend on a sibling that lands before it"
        else
          case " $KEEP " in *" $P "*) ;; *) KEEP="$KEEP $P" ;; esac
        fi
      done <<<"$AFTERS"
    fi
    BLOCK=""; DEPENDS=""; DEPS="[]"
    if [ "$FC_KIND" != rollout ] && [ "$i" != 0 ]; then
      BLOCK="${KEYS[1]} (hard)"
      DEPENDS="DEPENDS: ${KEYS[1]} hard — this slice imports the contract ($CONTRACT)"
      # BH-5520: this lane has no contract-path extraction, so it cannot check
      # "shares no file". The sibling stays hard; the log line shows the gap.
      if jq -e --argjson i "$i" '.[$i].imports_contract == false' "$FC_SPEC" >/dev/null 2>&1; then
        fc_log "$FC_BUILD" "child $n: imports_contract false refused — the board lane cannot check shared files — kept hard on the contract ${KEYS[1]}"
      fi
      if [ "$CAP" = 1 ]; then
        [ -n "${IDS[1]:-}" ] || { _fcb_fail "child $n depends on the contract, whose board id is unknown — nothing filed for it"; return 1; }
        DEPS=$(jq -c --argjson id "${IDS[1]}" '. + [$id]' <<<"$DEPS")
      fi
    fi
    for p in $(printf '%s\n' $KEEP | sort -n); do
      [ -n "${IDS[p]:-}" ] || { _fcb_fail "child $n depends on child $p, whose board id is unknown — nothing filed for it"; return 1; }
      BLOCK="${BLOCK:+$BLOCK, }${KEYS[p]} (hard)"
      DEPS=$(jq -c --argjson id "${IDS[p]}" '. + [$id]' <<<"$DEPS")
    done
    # A capable board carries the order in dependsOn: no text line beside it.
    [ "$FC_KIND" != rollout ] && [ "$CAP" = 1 ] && BLOCK=""
    HTML="$FC_BUILD/children/child-$n.html"
    { printf '%s\n\n' "$BODY"; fc_child_footer "$FC_KIND" "$FC_KEY" "$n" "$N" "$BLOCK" "$DEPENDS" "$CONTRACT"
      fc_owns_line "$FC_SPEC" "$i"; } | _fcb_html > "$HTML"
    REQ="$FC_BUILD/children/create-$n.json"
    jq -n --arg title "$CT" --rawfile desc "$HTML" --arg pri "$PRIORITY" --argjson cap "$CAP" \
          --argjson parent "$PARENT_ID_JSON" --argjson deps "$DEPS" \
      '{title: $title, description: $desc} + (if $pri != "" then {priority: $pri} else {} end)
       + (if $cap == 1 then {parentId: $parent, dependsOn: $deps} else {} end)' > "$REQ" 2>/dev/null
    jq -e 'type == "object" and (.title | length > 0)' "$REQ" >/dev/null 2>&1 \
      || { _fcb_fail "could not build the create request for child $n of $N — nothing sent"; return 1; }
    FILED_NEW=1
    if [ "$_FCB_DRY" = 1 ]; then
      _fcb_curl POST "$BASE/boards/$BOARD_ID/tickets" "$REQ" "$FC_KIND-$FC_KEY-$n"
      KEYS[n]="$FC_KEY.$n"; IDS[n]="\"{id of child $n}\""; URLS[n]=""
      i=$n; continue
    fi
    RESP=$(_fcb_curl POST "$BASE/boards/$BOARD_ID/tickets" "$REQ" "$FC_KIND-$FC_KEY-$n"); RC=$?
    KEY=$(printf '%s' "$RESP" | jq -r '(.ticket // .) | .key // empty | tostring' 2>/dev/null)
    ID=$(printf '%s' "$RESP" | jq -c '(.ticket // .) | .id // empty' 2>/dev/null)
    URL=$(printf '%s' "$RESP" | jq -r '(.ticket // .) | (.url // .href // empty) | tostring' 2>/dev/null)
    # A 2xx that names no ticket is not a ticket (D9).
    if [ "$RC" != 0 ] || [ -z "$KEY" ] || [ -z "$ID" ]; then
      _fcb_fail "create failed on child $n of $N (curl rc=$RC, key '${KEY:-none}', id ${ID:-none}) — $((n - 1)) filed, the master is not parked"; return 1
    fi
    grep -qE '^[A-Za-z]+-[0-9]+$' <<<"$KEY" \
      || { _fcb_fail "child $n of $N was created as id $ID but its key '$KEY' is not a board key — not recorded, resolve by hand"; return 1; }
    # RECORDED BEFORE THE LOOP ADVANCES: a run killed on child n+1 leaves an
    # honest partial record, and the rerun files only what is missing.
    _fcb_append "$FC_BUILD/children.txt" "$KEY"
    _fcb_append "$FC_BUILD/children-board.tsv" "$n	$KEY	$ID"
    KEYS[n]="$KEY"; IDS[n]="$ID"; URLS[n]="$URL"
    fc_log "$FC_BUILD" "child $n of $N filed as $KEY"
    i=$n
  done

  # ---- park the master, LAST ---------------------------------------------
  # Only when this run filed something: a complete record re-proven by a rerun
  # does not post a second comment on the client's thread.
  if [ "$FILED_NEW" = 1 ]; then
    [ "$FC_KIND" = rollout ] && WORD=waves || WORD=parts
    LI=""
    for n in $(seq 1 "$N"); do
      tk="${KEYS[n]}"
      # A link only when the board returned one (never a guessed URL).
      case "${URLS[n]}" in http://*|https://*) tk="<a href=\"$(printf '%s' "${URLS[n]}" | sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g')\">$tk</a>" ;; esac
      LI="$LI<li>$tk: $(printf '%s' "${TITLES[n]}" | _fcb_html | sed -e 's#^<p>##' -e 's#</p>$##')</li>"
    done
    COMMENT="<p>We split this one into $N $WORD and filed each as its own ticket. They are built in order, and this ticket stays open as the master until they land.</p><ol>$LI</ol>"
    # The adapter writes comment.json ({body}) and move.json from these; the
    # HTML goes to a file with no trailing newline so the body is byte for byte
    # the string above.
    printf '%s' "$COMMENT" > "$FC_BUILD/children/comment.html"
    if [ "$_FCB_DRY" = 1 ]; then
      TRK_REQ_FILE="$FC_BUILD/children/comment.json"; trk_board_comment "$FC_PARENT" "$FC_BUILD/children/comment.html"
      TRK_REQ_FILE="$FC_BUILD/children/move.json"; trk_board_transition "$FC_PARENT" in_progress
      fc_log "$FC_BUILD" "DRY RUN: nothing was filed — the commands are in $FC_BUILD/decompose-board.log"
      return 0
    fi
    # A failed comment or move is a WARN: the children exist and the record
    # says so, which is the result.
    TRK_REQ_FILE="$FC_BUILD/children/comment.json"
    trk_board_comment "$FC_PARENT" "$FC_BUILD/children/comment.html" >/dev/null \
      || fc_log "$FC_BUILD" "WARN: children are filed but the comment did not post on the master $FC_PARENT"
    # rc 0 only when the board's answer names in_progress (the adapter's check);
    # TRK_CURL_RC is curl's own rc, which is what the WARN has always named.
    TRK_REQ_FILE="$FC_BUILD/children/move.json"
    if trk_board_transition "$FC_PARENT" in_progress >/dev/null; then
      fc_log "$FC_BUILD" "master $FC_PARENT moved to in_progress"
    else
      fc_log "$FC_BUILD" "WARN: children are filed but the move of the master $FC_PARENT to in_progress did not take (curl rc=$TRK_CURL_RC)"
    fi
  fi
  if [ "$FILED_NEW" = 1 ]; then fc_log "$FC_BUILD" "filed into: $(paste -sd, "$FC_BUILD/children.txt")"
  else fc_log "$FC_BUILD" "already filed into: $(paste -sd, "$FC_BUILD/children.txt") — nothing re-filed, master not re-parked"; fi
  return 0
}
