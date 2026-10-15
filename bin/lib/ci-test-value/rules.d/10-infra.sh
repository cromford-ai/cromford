#!/bin/bash
# bin/lib/ci-test-value/rules.d/10-infra.sh — rule group infra. Owner: BH-6618.1.
# First match wins, in this order:
#   I1.cancelled  the job is cancelled or timed_out and the log names no failed
#                 unit (the driver wrote a `job:<name>` row).
#   I2.step       CTV_STEP matches a row of catalog/ci-test-value/infra-steps.tsv.
#   I3.pattern    the excerpt file matches a row of
#                 catalog/ci-test-value/infra-patterns.tsv.
# A catalog row is `<POSIX ERE>\t<why>`; the why column is the rule's why.

_CTV_RULES_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)

# _ctv_infra_rows <catalog file name> — the usable `ERE\twhy` rows, in file
# order. A blank line, a `#` line and a row with an empty field are skipped. A
# row whose ERE does not compile never matches (grep and `=~` answer rc 2).
_ctv_infra_rows() {
  local f="$_CTV_RULES_ROOT/catalog/ci-test-value/$1" line re why
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" == *$'\t'* ]] || continue
    re=${line%%$'\t'*}; why=${line#*$'\t'}
    [ -n "$re" ] && [ -n "$why" ] || continue
    printf '%s\t%s\n' "$re" "$why"
  done < "$f"
}

ctv_rule_infra() {
  local re why LC_ALL=C
  case "${CTV_JOB_CONCLUSION:-}" in
    cancelled|timed_out)
      if [[ "${CTV_UNIT:-}" == job:* ]]; then
        printf 'infra\tI1.cancelled\tjob %s, the log names no failed unit\n' "$CTV_JOB_CONCLUSION"
        return 0
      fi ;;
  esac
  if [ -n "${CTV_STEP:-}" ]; then
    while IFS=$'\t' read -r re why; do
      if [[ "$CTV_STEP" =~ $re ]]; then printf 'infra\tI2.step\t%s\n' "$why"; return 0; fi
    done < <(_ctv_infra_rows infra-steps.tsv)
  fi
  if [ -n "${CTV_EXCERPT_FILE:-}" ] && [ -f "$CTV_EXCERPT_FILE" ] && [ -r "$CTV_EXCERPT_FILE" ]; then
    while IFS=$'\t' read -r re why; do
      if grep -Eq -e "$re" "$CTV_EXCERPT_FILE" 2>/dev/null; then printf 'infra\tI3.pattern\t%s\n' "$why"; return 0; fi
    done < <(_ctv_infra_rows infra-patterns.tsv)
  fi
  return 1
}
