#!/bin/bash
# bin/lane-run-secrets.sh — the secrets a lane-run group app must hold for a lane.
#
#   bin/lane-run-secrets.sh <lane> <project>...
#       One line per secret: `<NAME> <need> <hub_source>`, the placeholders of
#       catalog/lane-run-secrets.d/<lane>.tsv expanded for each project, sorted
#       and de-duplicated. Names only: it never reads or prints a value.
#   bin/lane-run-secrets.sh --stage-cmd <app> <lane> <project>...
#       Prints (never runs) one shell command for the hub: it sources the hub
#       env files and pipes `NAME=value` lines into
#       `flyctl secrets import -a <app> --stage`, so no value is in argv or on
#       screen. It stops before it prints a line when a required variable is
#       empty. A `file:` row (the multi-line App key) gets a `#` line instead:
#       stage it by hand (fly/lane-run.toml).
#
# Exit: 0 = the list or the command is on stdout; 2 = bad input (stderr names
# it, stdout is empty). No network, no Fly call, no GitHub call, no file written.
# Doc: docs/notes/2026-10-21-BH-7848-lane-run-secrets.md
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

lrs_die() { echo "lane-run-secrets: $*" >&2; exit 2; }
lrs_usage() { lrs_die "usage: $0 [--stage-cmd <app>] <lane> <project>..."; }
lrs_up() { printf '%s' "$1" | tr '[:lower:].-' '[:upper:]__'; }

APP=""
if [ "${1:-}" = --stage-cmd ]; then
  APP="${2:-}"; shift 2 2>/dev/null || lrs_usage
  [[ $APP =~ ^[a-z0-9-]+$ ]] || lrs_die "bad app name '$APP' (want [a-z0-9-]+)"
fi
LANE="${1:-}"; shift 2>/dev/null || lrs_usage
[ "$#" -ge 1 ] || lrs_usage
[[ $LANE =~ ^[a-z0-9-]+$ ]] || lrs_die "bad lane '$LANE' (want [a-z0-9-]+)"
LIST="$ROOT/catalog/lane-run-secrets.d/$LANE.tsv"
[ -f "$LIST" ] || lrs_die "no secret list for lane '$LANE' ($LIST)"

# Each project: its name, its expanded <PROJECT> and its expanded <OWNER>.
declare -a P_UP=() P_OWN=()
for p in "$@"; do
  [[ $p =~ ^[A-Za-z0-9._-]+$ ]] || lrs_die "bad project '$p'"
  repo=$("$HERE/fleet-conf.sh" "$p" repo 2>/dev/null) || repo=""
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || lrs_die "project '$p' has no fleet.conf repo"
  P_UP+=("$(lrs_up "$p")"); P_OWN+=("$(lrs_up "${repo%%/*}")")
done

NAME_RE='^[A-Z][A-Z0-9_]*$'
OUT=""; n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
  nf=$(awk -F'\t' '{print NF}' <<<"$line")
  [ "$nf" = 4 ] || lrs_die "$LIST:$n: want 4 tab-separated fields, got $nf"
  IFS=$'\t' read -r name need src _ <<<"$line"
  case "$need" in required|optional) ;; *) lrs_die "$LIST:$n: need '$need' is not required|optional" ;; esac
  for i in "${!P_UP[@]}"; do
    en="${name//<PROJECT>/${P_UP[$i]}}"; en="${en//<OWNER>/${P_OWN[$i]}}"
    es="${src//<PROJECT>/${P_UP[$i]}}"; es="${es//<OWNER>/${P_OWN[$i]}}"
    [[ $en =~ $NAME_RE ]] || lrs_die "$LIST:$n: name '$name' does not expand to [A-Z][A-Z0-9_]*"
    [[ $es =~ ^(file:[a-z0-9.-]+|[a-z0-9.-]+\.env:[A-Z][A-Z0-9_]*)$ ]] \
      || lrs_die "$LIST:$n: hub_source '$src' is not <envfile>:<VAR> or file:<envfile>"
    OUT+="$en $need $es"$'\n'
  done
done < "$LIST"
OUT=$(printf '%s' "$OUT" | LC_ALL=C sort -u)
[ -n "$OUT" ] || lrs_die "$LIST has no rows"

if [ -z "$APP" ]; then
  printf '%s\n' "$OUT"
  exit 0
fi

# --stage-cmd: values only ever appear as "$VAR" references in the printout.
# shellcheck source=bin/lib/env-path.sh
. "$HERE/lib/env-path.sh" || lrs_die "$HERE/lib/env-path.sh did not load"
HENV=$(harness_env_dir "${HARNESS:-$ROOT}")
FILES=""; CHECK=""; PUT=""; BYHAND=""
while read -r en need es; do
  if [[ $es == file:* ]]; then
    BYHAND+="# $en: multi-line, stage it by hand from $HENV/${es#file:} (fly/lane-run.toml)"$'\n'
    continue
  fi
  f="${es%%:*}"; v="${es#*:}"
  [[ " $FILES " == *" $f "* ]] || FILES+=" $f"
  if [ "$need" = required ]; then
    CHECK+=" \"\${$v:?is empty in $f}\""
    PUT+=" printf '$en=%s\\n' \"\$$v\";"
  else
    PUT+=" [ -z \"\${$v:-}\" ] || printf '$en=%s\\n' \"\$$v\";"
  fi
done <<<"$OUT"
SRC=""
for f in $FILES; do SRC+=" . $(printf '%q' "$HENV/$f");"; done
printf '( set -a;%s%s%s ) | flyctl secrets import -a %s --stage\n' \
  "$SRC" "${CHECK:+ :$CHECK;}" "$PUT" "$APP"
printf '%s' "$BYHAND"
exit 0
