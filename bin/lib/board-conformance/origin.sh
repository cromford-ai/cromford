# shellcheck shell=bash
# bin/lib/board-conformance/origin.sh — the production-origin probe (BH-3947,
# BH-3960). Sourced, never executed.
#
#   bc_probe_origin <prod> <base> <token> <migration_token> [<prefix>]
#     rc 0 always, one bc_item for each of origin.health, internal.version and
#     internal.migrations. At most 3 GETs, through bc_get. <migration_token> may
#     be empty: internal.migrations is then unverified and no request is made.
#     A <prod> of "-" or empty makes origin.health unverified with no request.
#     A <prefix> under /api/hosted-board/ (BH-8918, docs/HOSTED-BOARD.md) is a
#     board the jobs worker serves: it has no app internals, so both internal
#     items are unverified and no request is made for them.
#   origin.health        GET <prod>/api/health, no token: 2xx ok; 5xx ok (note
#                        "5xx: present, reporting unwell"); 404 missing; 000
#                        unverified; other malformed.
#   internal.version     GET <base>/api/internal/version, board token: 2xx with a
#                        non-empty string .sha ok; any other 2xx malformed; 404
#                        missing; 000/5xx unverified; other (401/403…) malformed.
#   internal.migrations  GET <base>/api/internal/migrations/status, migration
#                        token: 2xx with applied+pending arrays, or a non-empty
#                        targets map whose every value has an applied array, ok;
#                        any other 2xx malformed; 404 missing; 000/5xx
#                        unverified; other malformed.
#   Notes carry HTTP codes and a sha prefix only, never a token.

bc_probe_origin() {
  local prod="${1:-}" base="${2:-}" tok="${3:-}" mt="${4:-}" prefix="${5:-}" body code sha
  body=$(mktemp) || {
    bc_item origin.health unverified "mktemp failed"
    bc_item internal.version unverified "mktemp failed"
    bc_item internal.migrations unverified "mktemp failed"
    return 0
  }

  if [ -z "$prod" ] || [ "$prod" = - ]; then
    bc_item origin.health unverified "no prod origin"
  else
    code=$(bc_get "${prod%/}/api/health" "$body")
    case "$(bc_class "$code")" in
      2xx) bc_item origin.health ok "" ;;
      5xx) bc_item origin.health ok "5xx: present, reporting unwell" ;;
      404) bc_item origin.health missing "" ;;
      000) bc_item origin.health unverified "no answer" ;;
      *)   bc_item origin.health malformed "HTTP $code" ;;
    esac
  fi

  case "$prefix" in
    /api/hosted-board/*)
      bc_item internal.version unverified "hosted board: the jobs worker serves no app internals"
      bc_item internal.migrations unverified "hosted board: the jobs worker serves no app internals"
      rm -f "$body"
      return 0 ;;
  esac

  code=$(bc_get "${base%/}/api/internal/version" "$body" "$tok")
  case "$(bc_class "$code")" in
    2xx)
      if jq -e '(.sha|type)=="string" and (.sha|length)>0' "$body" >/dev/null 2>&1; then
        sha=$(jq -r '.sha' "$body" 2>/dev/null)
        bc_item internal.version ok "sha ${sha:0:12}"
      else
        bc_item internal.version malformed "2xx without a .sha string"
      fi ;;
    404)     bc_item internal.version missing "" ;;
    000|5xx) bc_item internal.version unverified "HTTP $code" ;;
    *)       bc_item internal.version malformed "HTTP $code" ;;
  esac

  if [ -z "$mt" ]; then
    bc_item internal.migrations unverified "no MIGRATION_TOKEN"
  else
    code=$(bc_get "${base%/}/api/internal/migrations/status" "$body" "$mt")
    case "$(bc_class "$code")" in
      2xx)
        if jq -e '((.applied|type)=="array" and (.pending|type)=="array")
            or ((.targets|type)=="object" and (.targets|length)>0
                and all(.targets[]; type=="object" and (.applied|type)=="array"))' "$body" >/dev/null 2>&1; then
          bc_item internal.migrations ok ""
        else
          bc_item internal.migrations malformed "2xx with neither applied+pending arrays nor a targets map"
        fi ;;
      404)     bc_item internal.migrations missing "" ;;
      000|5xx) bc_item internal.migrations unverified "HTTP $code" ;;
      *)       bc_item internal.migrations malformed "HTTP $code" ;;
    esac
  fi
  rm -f "$body"
  return 0
}
