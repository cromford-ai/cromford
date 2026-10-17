# shellcheck shell=bash
# bin/lib/pm-signals-adapter.sh — the row helpers the bin/pm-signals.d/ adapters
# share (BH-7259). Sourced, never executed: no `set`, no output and no read at
# source time. Every name starts with _pmsa_, so bin/pm-signals.sh never counts
# one of them as the file's pms_ function.
#
# A row is one JSON line: {id, source, metric, value, window, link, status}.
# value is a number, or null when status is not "ok". A source with no read
# path is "not-configured" with value null: never a guessed number.

# _pmsa_root — the harness root, ${HARNESS:-${H:-}} (D43); empty = no root.
_pmsa_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _pmsa_row <id> <source> <metric> <value-json> <window> <link> <status>
# A number is printed in its plain form (jq 1.7 keeps a literal like 1.4000).
_pmsa_row() {
  jq -nc --arg i "$1" --arg s "$2" --arg m "$3" --argjson v "$4" --arg w "$5" --arg l "$6" --arg st "$7" \
    '{id:$i, source:$s, metric:$m, value:(if ($v | type) == "number" then $v + 0 else $v end), window:$w, link:$l, status:$st}'
}

# _pmsa_nc <id> <source> <metric> <window> <link> — a not-configured row.
_pmsa_nc() { _pmsa_row "$1" "$2" "$3" null "$4" "$5" not-configured; }

# _pmsa_err <id> <source> <metric> <window> <link> — an error row: the read
# path is configured and did not answer.
_pmsa_err() { _pmsa_row "$1" "$2" "$3" null "$4" "$5" error; }

# _pmsa_now — the window clock: PM_SIGNALS_NOW (the runner exports it).
_pmsa_now() { printf '%s\n' "${PM_SIGNALS_NOW:-$(date +%s)}"; }

# _pmsa_iso <epoch> — UTC YYYY-MM-DDTHH:MM:SSZ.
_pmsa_iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# _pmsa_fleet <project> <field> — one fleet registry field. Tries
# bin/fleet-conf.sh beside this lib, then the root's copy. Prints nothing and
# returns 1 when the project or the field is unknown.
_pmsa_fleet() {
  local f out
  for f in "$(dirname "${BASH_SOURCE[0]}")/../fleet-conf.sh" "$(_pmsa_root)/bin/fleet-conf.sh"; do
    [ -r "$f" ] || continue
    out=$(bash "$f" "$1" "$2" 2>/dev/null) || continue
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  done
  return 1
}

# _pmsa_project_rows <project> <source.metric:window>... — the per-project
# reader. It reads the optional snapshot $HARNESS/state/pm-data/<project>.json,
#   {"metrics":{"<source>.<metric>":{"value":<number>,"link":"<url>"}}}
# A key with a numeric value gives an "ok" row (link: the key's link, else the
# file). A missing file, a missing key or a non-number gives a not-configured
# row. A file that does not parse gives an error row for every key.
_pmsa_project_rows() {
  local p="$1" root rel f spec key win src metric got v l parse=ok
  shift
  root=$(_pmsa_root)
  rel="state/pm-data/$p.json"; f="$root/$rel"
  if [ -z "$root" ] || [ ! -r "$f" ]; then parse=none
  elif ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then parse=bad; fi
  for spec in "$@"; do
    key=${spec%%:*}; win=${spec#*:}; src=${key%%.*}; metric=${key#*.}
    case "$parse" in
      none) _pmsa_nc "$key" "$src" "$metric" "$win" "$rel" || return 1; continue ;;
      bad)  _pmsa_err "$key" "$src" "$metric" "$win" "$rel" || return 1; continue ;;
    esac
    got=$(jq -c --arg k "$key" '.metrics[$k] // {} | if type == "object" then [.value, (.link // "")] else [null, ""] end' "$f" 2>/dev/null) || return 1
    v=$(jq -c '.[0]' <<<"$got"); l=$(jq -r '.[1] | tostring' <<<"$got")
    [ -n "$l" ] || l="$rel"
    if jq -e 'type == "number"' <<<"$v" >/dev/null 2>&1; then
      _pmsa_row "$key" "$src" "$metric" "$v" "$win" "$l" ok || return 1
    else
      _pmsa_nc "$key" "$src" "$metric" "$win" "$rel" || return 1
    fi
  done
  return 0
}
