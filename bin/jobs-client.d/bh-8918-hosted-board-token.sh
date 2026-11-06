# shellcheck shell=bash
# bin/jobs-client.d/bh-8918-hosted-board-token.sh — BH-8918: issue or revoke a
# hosted Board API token (docs/HOSTED-BOARD.md). The token is 32 random bytes
# made HERE, as hex; only its sha256 goes to POST /api/hosted-board-admin/setup,
# so the worker never holds it. After a 200 that names the token id the verb
# prints the token ONCE, with the two env lines to set, and nothing else keeps
# it: no log line, no file. Any other answer prints no token.
#   issue <project> <KEY_PREFIX>  a system token for one project, and the
#                                 project's board (product-board) if absent
#   issue --operator              an operator token: every project, no board
#   revoke <project|*> <tokenId>  sets revoked_at once
# rc: 0 done, 2 usage or not found (404), 9 conflict (409), 1 anything else.
#: hosted-board-token issue <project> <KEY_PREFIX> | issue --operator | revoke <project|*> <tokenId>
jc_verb_hosted_board_token() {
  local sub="${1:-}" project prefix role=system tok hash body out rc tid var
  case "$sub" in
    issue)
      if [ "${2:-}" = --operator ] && [ $# -eq 2 ]; then
        project='*'; role=operator
      elif [ $# -eq 3 ]; then
        project="$2"; prefix="$3"
      else
        echo "usage: jobs-client.sh hosted-board-token issue <project> <KEY_PREFIX> | issue --operator" >&2; return 2
      fi
      tok=$(od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n')
      [ "${#tok}" -eq 64 ] || { echo "hosted-board-token: could not read 32 random bytes" >&2; return 1; }
      hash=$(printf '%s' "$tok" | sha256sum | cut -d' ' -f1)
      if [ "$role" = operator ]; then
        body=$(jq -cn --arg h "$hash" '{project:"*", role:"operator", tokenHash:$h}')
      else
        body=$(jq -cn --arg p "$project" --arg k "$prefix" --arg h "$hash" '{project:$p, keyPrefix:$k, role:"system", tokenHash:$h}')
      fi
      out=$(_jobs_req POST /api/hosted-board-admin/setup "$body"); rc=$?
      tid=$(jq -r '.tokenId // empty' <<<"$out" 2>/dev/null)
      if [ "$rc" -ne 0 ] || [ "$tid" != "${hash:0:12}" ]; then
        echo "hosted-board-token: not issued (rc $rc): $(jq -r '.error // empty' <<<"$out" 2>/dev/null)" >&2
        [ "$rc" -eq 0 ] && rc=1
        return "$rc"
      fi
      echo "hosted-board-token: issued $tid for $project ($role)"
      echo "The token is shown once. Store it now:"
      if [ "$role" = operator ]; then
        echo "HOSTED_BOARD_OPERATOR_TOKEN=$tok"
      else
        var=$(printf '%s' "$project" | tr 'a-z-' 'A-Z_')
        echo "Set in env/$project.env:"
        echo "${var}_API_BASE=${JOBS_URL:-}"
        echo "${var}_INTERNAL_API_TOKEN=$tok"
        case "$var" in *[0-9]*) echo "NOTE: the variable prefix must be letters and underscores only (docs/BOARD-API-CONTRACT.md); rename ${var}_ in both lines." ;; esac
      fi
      return 0 ;;
    revoke)
      [ $# -eq 3 ] || { echo "usage: jobs-client.sh hosted-board-token revoke <project|*> <tokenId>" >&2; return 2; }
      body=$(jq -cn --arg p "$2" --arg t "$3" '{project:$p, tokenId:$t}')
      out=$(_jobs_req POST /api/hosted-board-admin/revoke "$body"); rc=$?
      if [ "$rc" -ne 0 ]; then echo "hosted-board-token: not revoked (rc $rc)" >&2; return "$rc"; fi
      echo "hosted-board-token: revoked $(jq -r '.tokenId' <<<"$out") at $(jq -r '.revokedAt' <<<"$out")"
      return 0 ;;
    *)
      echo "usage: jobs-client.sh hosted-board-token issue <project> <KEY_PREFIX> | issue --operator | revoke <project|*> <tokenId>" >&2
      return 2 ;;
  esac
}
