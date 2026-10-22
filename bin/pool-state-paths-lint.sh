#!/bin/bash
# bin/pool-state-paths-lint.sh [--file <script>] [--catalog <json>]
#                              [--manifests <dir>] [--trace <paths.txt>]
# — BH-7431 (BH-6896 S4): every state/ path the pool tick names has a class.
#
# Option (a) of the BH-6896 note runs the pool tick on a machine from a
# snapshot. A state/ path with no catalog row and no snapshot-list line has no
# class: nobody decided whether it rides to the machine, comes back, or stays
# on the hub. This lint fails on such a path.
#
# A state/<seg> token passes when:
#   - catalog/state-paths.json has a row with path == <seg>, or
#   - catalog/lane-run-inputs.d/fly-pool.ro, .rw or .wo (the .wo when present)
#     has a non-comment path line whose glob starts with state/<seg>/ or
#     equals state/<seg>.
# <seg> is the whole top-level segment: state/pool-stats is not state/pool.
#
# File mode (the default, target bin/fly-pool.sh): each line that is not a `#`
# comment is scanned for every state/<seg> token. The token must not follow a
# character of [A-Za-z0-9_.-] (so mystate/x is not one), <seg> is the longest
# run of [A-Za-z0-9_.-], and a trailing `.` is dropped (a sentence end, as in
# "parked in state/pool."). A token right after /data/harness/ is skipped: that
# is the build machine's root, not this box's state (bin/fly-pool.sh `mput`).
#
# Trace mode (--trace): a normalised trace list, the BH-6896 note's Appendix C
# form (`state/pool/<p>/<KEY>.spawns`), one path a line, an optional
# `<state>TAB` prefix. Only lines that start with state/ are checked.
#
# Output: one `UNCLASSIFIED state/<seg> (<file>:<line>)` per miss, then one
# last line `pool-state-paths: unclassified=<n> checked=<m>`, where <m> counts
# the tokens (file mode) or trace lines (trace mode) checked.
#
# rc 0 = clean (or skipped through the skip-guardrail escape hatch).
# rc 1 = a miss.
# rc 2 = could not check: no jq, the catalog is missing, not JSON or has no
#        .paths array, the target or trace is missing, the manifest dir is not
#        a directory, or an unknown option.
#
# CI runs it through tests/pool-state-paths.bh-7431-test.sh (case T6) and
# tests/fly-pool-state-trace.bh-7431-test.sh. It reads and writes no state.
set -uo pipefail
set -f
SELF="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SELF/.." && pwd)"
# shellcheck source=../guardrails/lib/escape-hatch.sh
. "$REPO/guardrails/lib/escape-hatch.sh" 2>/dev/null || true
declare -F guardrail_escape_hatch >/dev/null \
  && guardrail_escape_hatch pool-state-paths && exit 0

say() { echo "pool-state-paths: $*" >&2; }
FILE="$REPO/bin/fly-pool.sh"
CATALOG="$REPO/catalog/state-paths.json"
MDIR="$REPO/catalog/lane-run-inputs.d"
TRACE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file)      FILE="${2:-}"; shift 2 || { say "--file needs a path"; exit 2; } ;;
    --catalog)   CATALOG="${2:-}"; shift 2 || { say "--catalog needs a path"; exit 2; } ;;
    --manifests) MDIR="${2:-}"; shift 2 || { say "--manifests needs a dir"; exit 2; } ;;
    --trace)     TRACE="${2:-}"; shift 2 || { say "--trace needs a path"; exit 2; } ;;
    -h|--help)   sed -n '2,39p' "$0"; exit 0 ;;
    *)           say "unknown option '$1'"; exit 2 ;;
  esac
done

# --- what is classified -------------------------------------------------------
command -v jq >/dev/null 2>&1 || { say "jq not found, cannot read $CATALOG"; exit 2; }
[ -r "$CATALOG" ] || { say "catalog $CATALOG is missing or unreadable"; exit 2; }
ROWS=$(jq -r 'if (.paths | type) == "array" then .paths[] | .path | strings else error("no .paths array") end' "$CATALOG" 2>/dev/null) \
  || { say "catalog $CATALOG is not JSON with a .paths array"; exit 2; }
[ -d "$MDIR" ] || { say "manifest dir $MDIR is not a directory"; exit 2; }
declare -A OK=()
while IFS= read -r p; do [ -n "$p" ] && OK[$p]=catalog; done <<<"$ROWS"
for m in ro rw wo; do
  f="$MDIR/fly-pool.$m"
  [ -f "$f" ] || continue
  [ -r "$f" ] || { say "manifest $f is unreadable"; exit 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in ''|'#'*|'@'*) continue ;; esac
    g=${line%%[[:space:]]*}
    case "$g" in state/*) ;; *) continue ;; esac
    g=${g#state/}; g=${g%%/*}
    [ -n "$g" ] && OK[$g]="fly-pool.$m"
  done < "$f"
done

# --- the scan -----------------------------------------------------------------
MISS=0; CHECKED=0
# check <seg> <where>
check() {
  CHECKED=$((CHECKED + 1))
  [ -n "${OK[$1]:-}" ] && return 0
  MISS=$((MISS + 1))
  printf 'UNCLASSIFIED state/%s (%s)\n' "$1" "$2"
}

RE_TOK='(^|[^A-Za-z0-9_.-])state/([A-Za-z0-9_.-]+)'
if [ -n "$TRACE" ]; then
  [ -f "$TRACE" ] && [ -r "$TRACE" ] || { say "trace $TRACE is missing or unreadable"; exit 2; }
  N=0
  while IFS= read -r line || [ -n "$line" ]; do
    N=$((N + 1))
    line=${line%$'\r'}; line=${line##*$'\t'}
    case "$line" in state/?*) ;; *) continue ;; esac
    seg=${line#state/}; seg=${seg%%/*}
    check "$seg" "$TRACE:$N"
  done < "$TRACE"
else
  [ -f "$FILE" ] && [ -r "$FILE" ] || { say "target $FILE is missing or unreadable"; exit 2; }
  N=0
  while IFS= read -r line || [ -n "$line" ]; do
    N=$((N + 1))
    case "$line" in *state/*) ;; *) continue ;; esac
    trim=${line#"${line%%[![:space:]]*}"}
    case "$trim" in '#'*) continue ;; esac
    rest="$line"
    while [[ $rest =~ $RE_TOK ]]; do
      pre=${rest%%"${BASH_REMATCH[0]}"*}${BASH_REMATCH[1]}
      seg=${BASH_REMATCH[2]}
      rest=${rest#*"${BASH_REMATCH[0]}"}
      while [ "${seg%.}" != "$seg" ]; do seg=${seg%.}; done
      [ -n "$seg" ] || continue
      case "$pre" in */data/harness/) continue ;; esac
      check "$seg" "$FILE:$N"
    done
  done < "$FILE"
fi

echo "pool-state-paths: unclassified=$MISS checked=$CHECKED"
[ "$MISS" = 0 ] || exit 1
exit 0
