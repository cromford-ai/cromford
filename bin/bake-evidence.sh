#!/bin/bash
# bin/bake-evidence.sh — print a bounded digest of this box's pool-bake evidence.
#
# Usage: bin/bake-evidence.sh [--lines N] [--captures M] [--max-bytes B]
#   --lines N      keep the last N phase lines of each pool (default 10)
#   --captures M   read the newest M logs/fly-image-build/*.log (default 6)
#   --max-bytes B  cut the digest at B bytes, on a line end (default 24576)
#
# Reads $HARNESS/logs/fleet-propagate.log and fleet-propagate-cron.log (when
# present) and the bake captures under $HARNESS/logs/fly-image-build/. Prints:
#   # bake evidence (BH-6259) host=<host> at=<UTC> sources=<files read>
#   ## bake phases (last N per pool)
#   <the matching log lines, time order>
#   ## captures (newest M, logs/fly-image-build/)
#   ### <capture file>
#   <its pool=... header line, then its '## step timings' lines, at most 80>
#   # truncated at B bytes         (only when the cap cut the output)
# A line that carries a token value (x-access-token:<value>, ghp_, ghs_,
# github_pat_) is dropped. Read-only: it writes no file.
#
# bin/fly-pool.sh (push_bake_evidence) copies this digest onto a cromford
# pool machine at dispatch, to /data/harness/state/bake-evidence.txt.
#
# Exit: 0 = digest printed (at least one phase line or capture);
#       3 = nothing found, one '# bake evidence (BH-6259): none on <host>' line;
#       2 = bad argument (message on stderr).
set -uo pipefail
export LC_ALL=C
H="${HARNESS:-/root/harness}"
LINES_N=10; CAPS_M=6; MAX_B=24576

usage() { echo "usage: bin/bake-evidence.sh [--lines N] [--captures M] [--max-bytes B]" >&2; exit 2; }
posint() { case "${2:-}" in ''|*[!0-9]*|0*) echo "bake-evidence: $1 needs a positive integer, got '${2:-}'" >&2; exit 2 ;; esac; }
while [ $# -gt 0 ]; do
  case "$1" in
    --lines)     posint "$1" "${2:-}"; LINES_N=$2; shift 2 ;;
    --captures)  posint "$1" "${2:-}"; CAPS_M=$2; shift 2 ;;
    --max-bytes) posint "$1" "${2:-}"; MAX_B=$2; shift 2 ;;
    -h|--help)   usage ;;
    *) echo "bake-evidence: unknown argument '$1'" >&2; usage ;;
  esac
done

HOST="${HOSTNAME:-$(uname -n)}"
KEEP_RE='pool [A-Za-z0-9._-]+: (bake phases |outer timeout hit |bake ran [0-9]+s, past )'
SECRET_RE='x-access-token:[^$]|ghp_|ghs_|github_pat_'

SOURCES=() LOGS=()
for f in "$H/logs/fleet-propagate.log" "$H/logs/fleet-propagate-cron.log"; do
  [ -r "$f" ] && { LOGS+=("$f"); SOURCES+=("logs/${f##*/}"); }
done

PHASES=""
if [ ${#LOGS[@]} -gt 0 ]; then
  # Both logs carry the same STAMP prefix, so sort -u is time order with no
  # repeat. Then keep the last N lines of each pool, still in time order.
  PHASES=$(grep -hE "$KEEP_RE" "${LOGS[@]}" 2>/dev/null | grep -vE "$SECRET_RE" | sort -u \
    | awk -v n="$LINES_N" '
        { line[NR] = $0
          if (match($0, /pool [A-Za-z0-9._-]+:/)) pool[NR] = substr($0, RSTART, RLENGTH); else pool[NR] = ""
          seen[pool[NR]]++ }
        END { for (i = 1; i <= NR; i++) { left[pool[i]]++
                if (seen[pool[i]] - left[pool[i]] < n) print line[i] } }')
fi

CAPS=()
if [ -d "$H/logs/fly-image-build" ]; then
  while IFS= read -r f; do [ -n "$f" ] && CAPS+=("$f"); done <<< "$(
    find "$H/logs/fly-image-build" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | head -n "$CAPS_M" | cut -d' ' -f2-)"
fi
[ ${#CAPS[@]} -gt 0 ] && SOURCES+=("logs/fly-image-build/")

if [ -z "$PHASES" ] && [ ${#CAPS[@]} -eq 0 ]; then
  echo "# bake evidence (BH-6259): none on $HOST"
  exit 3
fi

SRC=$(IFS=,; printf '%s' "${SOURCES[*]}")
OUT="# bake evidence (BH-6259) host=$HOST at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') sources=${SRC:--}
## bake phases (last $LINES_N per pool)"
[ -n "$PHASES" ] && OUT+=$'\n'"$PHASES"
OUT+=$'\n'"## captures (newest $CAPS_M, logs/fly-image-build/)"
for f in "${CAPS[@]}"; do
  OUT+=$'\n'"### ${f##*/}"
  SEC=$(awk 'NR == 2 { print; next }
             /^## step timings/ { s = 1; next }
             s && /^## / { exit }
             s && k < 80 { print; k++ }' "$f" 2>/dev/null | grep -vE "$SECRET_RE")
  [ -n "$SEC" ] && OUT+=$'\n'"$SEC"
done
OUT+=$'\n'

if [ "${#OUT}" -le "$MAX_B" ]; then
  printf '%s' "$OUT"
else
  # Cut on the last line end inside the cap, then say the digest is cut.
  CUT="${OUT:0:$MAX_B}"
  CUT="${CUT%$'\n'*}"
  printf '%s\n# truncated at %s bytes\n' "$CUT" "$MAX_B"
fi
exit 0
