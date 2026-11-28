# shellcheck shell=bash
# bin/jobs-client.d/bh-9554-custody.sh — BH-9554: the ticket custody verbs
# (bin/lib/jobs/custody.sh). rc 0 = taken (the body on stdout), 9 = refused
# (409, the body says why), 2 = no custody row, 1 = the DB did not take it
# (one alert line written), 3 = bad arguments. docs/CUSTODY.md.
#: custody <claim|renew|release|next|settle|act|due|row|gaps> ... (docs/CUSTODY.md)
jc_verb_custody() {
  # shellcheck source=bin/lib/jobs/custody.sh
  . "$(dirname "${BASH_SOURCE[0]}")/../lib/jobs/custody.sh" || return 1
  local sub="${1:-}" rc
  case "$sub" in
    claim|renew|release|next|settle|act|due|row|gaps) shift ;;
    *) echo "usage: custody <claim|renew|release|next|settle|act|due|row|gaps> ..." >&2; return 3 ;;
  esac
  "custody_$sub" "$@"; rc=$?
  case "$rc" in 0|9) echo ;; esac
  return "$rc"
}
