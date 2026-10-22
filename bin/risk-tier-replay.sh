#!/bin/bash
# bin/risk-tier-replay.sh — BH-7041: replay past verdict heads through the risk
# tier (bin/lib/risk-tier.sh) and report what the low-small class would sign
# off. READ ONLY: it posts nothing, writes no verdict, no status and no row.
#
# Usage:
#   risk-tier-replay.sh <heads.tsv> [--compare-dir DIR]
#   risk-tier-replay.sh --help
#
# heads.tsv: one head per line, `<owner/repo>\t<pr>\t<head sha>\t<verdict>[\t<base>]`
# (verdict is the lead's MERGE or BLOCK; a line starting `#` is skipped). For
# each head it reads <DIR>/<head>.json when present; else GET
# repos/<repo>/compare/<base>...<head> (base from the column, else the PR's
# .base.sha from GET repos/<repo>/pulls/<pr>) and saves a readable answer to
# DIR, so a second run reads nothing from GitHub. DIR defaults to
# $HARNESS/state/risk-tier-replay/compare.
#
# The rules are the live settings rows (bin/jobs-client.sh setting_get) and the
# live lead protected paths, read once. rt_low_small runs on each head
# rt_classify calls medium (the tier is passed in, as rt_low_small_apply does)
# with RT_LOW_SMALL_MODE forced to enforce: it answers what enforce would do.
#
# Output, one row per head:
#   <repo>#<pr>\t<head12>\t<verdict>\t<tier>\t<low-small yes|no|n/a>\t<reason>
# tier is low|medium|high, or `unreadable` (a compare it could not read; never
# low). Then one summary line:
#   replay: heads=N low_before=A low_small=L blocks=B blocks_low_small=K unreadable=U
# and one `BLOCK low-small: <repo>#<pr> @<head12> <reason>` line per K.
# rc 0 after the summary; rc 2 on a bad argument or a malformed input line
# (nothing is replayed then).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
H="${HARNESS:-/root/harness}"

usage() { sed -n '/^# Usage:/,/^# rc 0/p' "$0" | sed 's/^# \{0,1\}//'; }
IN=""; DIRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --compare-dir) [ $# -ge 2 ] || { echo "risk-tier-replay: --compare-dir needs a value" >&2; exit 2; }; DIRC="$2"; shift 2 ;;
    -*) echo "risk-tier-replay: unknown flag $1" >&2; exit 2 ;;
    *) [ -z "$IN" ] || { echo "risk-tier-replay: one heads file only" >&2; exit 2; }; IN="$1"; shift ;;
  esac
done
[ -n "$IN" ] && [ -r "$IN" ] || { echo "risk-tier-replay: need a readable heads.tsv (see --help)" >&2; exit 2; }
DIRC="${DIRC:-$H/state/risk-tier-replay/compare}"
mkdir -p "$DIRC" || { echo "risk-tier-replay: cannot make $DIRC" >&2; exit 2; }

# Validate every line before any read: a malformed file replays nothing.
LN=0
while IFS= read -r line || [ -n "$line" ]; do
  LN=$((LN + 1))
  case "$line" in ''|'#'*) continue ;; esac
  IFS=$'\t' read -r r p h v b x <<<"$line"
  if ! [[ "$r" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$p" =~ ^[0-9]+$ && "$h" =~ ^[0-9a-fA-F]{40}$ && -n "$v" && -z "${x:-}" ]] \
     || { [ -n "${b:-}" ] && ! [[ "$b" =~ ^[A-Za-z0-9_./-]+$ ]]; }; then
    echo "risk-tier-replay: line $LN is not <owner/repo>\\t<pr>\\t<40-hex head>\\t<verdict>[\\t<base>]" >&2; exit 2
  fi
done < "$IN"

for f in bin/jobs-client.sh bin/lib/gh-rest.sh bin/lib/risk-tier.sh; do
  [ -r "$ROOT/$f" ] || { echo "risk-tier-replay: missing $ROOT/$f" >&2; exit 2; }
done
# shellcheck source=bin/jobs-client.sh
. "$ROOT/bin/jobs-client.sh"
# shellcheck source=bin/lib/gh-rest.sh
. "$ROOT/bin/lib/gh-rest.sh"
# shellcheck source=bin/lib/risk-tier.sh
. "$ROOT/bin/lib/risk-tier.sh"
rt_rules_load
[ -n "${RT_LOW_SMALL_WHY:-}" ] && echo "risk-tier-replay: note: $RT_LOW_SMALL_WHY (replayed as enforce anyway)" >&2
RT_LOW_SMALL_MODE=enforce

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/risk-tier-replay.XXXXXX") || exit 2
trap 'rm -rf "$TMPD"' EXIT

# fetch <repo> <pr> <head> <base> — the compare into $DIRC/<head>.json; rc 1 when unreadable.
fetch() {
  local repo="$1" pr="$2" head="$3" base="$4" f="$DIRC/$3.json"
  [ -s "$f" ] && return 0
  if [ -z "$base" ]; then
    gh_rest GET "repos/$repo/pulls/$pr" > "$TMPD/pr.json" 2>/dev/null || return 1
    base=$(jq -r '.base.sha // empty' "$TMPD/pr.json" 2>/dev/null)
    [ -n "$base" ] || return 1
  fi
  gh_rest GET "repos/$repo/compare/$(jq -rn --arg b "$base" '$b|@uri')...$head" > "$TMPD/cmp.json" 2>/dev/null || return 1
  jq -e '(.files | type) == "array"' "$TMPD/cmp.json" >/dev/null 2>&1 || return 1
  mv -f "$TMPD/cmp.json" "$f"
}

N=0; LOWB=0; LS=0; BL=0; BLS=0; UNR=0; BLINES=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  IFS=$'\t' read -r r p h v b <<<"$line"
  h=$(printf '%s' "$h" | tr 'A-F' 'a-f'); v=$(printf '%s' "$v" | tr 'a-z' 'A-Z')
  N=$((N + 1)); [ "$v" = BLOCK ] && BL=$((BL + 1))
  tier=unreadable; lsa=no; why="compare not readable"
  if fetch "$r" "$p" "$h" "${b:-}"; then
    out=$(rt_classify "$DIRC/$h.json" "$r") && [ -n "$out" ] && IFS=$'\t' read -r tier why _ <<<"$out" || { tier=unreadable; why="compare files unreadable"; }
  fi
  case "$tier" in
    low) LOWB=$((LOWB + 1)); lsa=n/a ;;
    high) lsa=n/a ;;
    medium)
      lout=$(rt_low_small "$DIRC/$h.json" "$r" "$tier"); IFS=$'\t' read -r lsa lwhy <<<"$lout"
      [ "$lsa" = yes ] || lsa=no
      why="${lwhy:-compare files unreadable}" ;;
  esac
  [ "$tier" = unreadable ] && UNR=$((UNR + 1))
  if [ "$lsa" = yes ]; then
    LS=$((LS + 1))
    [ "$v" = BLOCK ] && { BLS=$((BLS + 1)); BLINES="${BLINES}BLOCK low-small: $r#$p @${h:0:12} $why"$'\n'; }
  fi
  printf '%s#%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$p" "${h:0:12}" "$v" "$tier" "$lsa" "$(printf '%s' "$why" | tr '\t\n' '  ')"
done < "$IN"
echo "replay: heads=$N low_before=$LOWB low_small=$LS blocks=$BL blocks_low_small=$BLS unreadable=$UNR"
printf '%s' "$BLINES"
exit 0
