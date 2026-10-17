# shellcheck shell=bash
# pm-signals adapter: PRD rescore partials for the project (BH-7259).
# Read path: the newest *.json (mtime) in $HARNESS/state/prd-rescore/<project>/,
# shape {"criteria":[{"id","status"}]} (or the array in .results). No producer
# in this repo writes it yet; a rescore lane or a person does.
# Rows prd-rescore.partial (status partial), prd-rescore.failed (fail or
# failed) and prd-rescore.criteria (all), any case; metric criteria, window
# latest, link: that file. No dir or no file = one prd-rescore.partial
# not-configured row. A file that does not parse = one error row.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/pm-signals-adapter.sh" || return 1
pms_prd_rescore() {
  local p="$1" root d f rel counts
  root=$(_pmsa_root); d="$root/state/prd-rescore/$p"
  f=""
  if [ -n "$root" ] && [ -d "$d" ]; then
    f=$(find "$d" -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
  fi
  if [ -z "$f" ]; then
    _pmsa_nc prd-rescore.partial prd-rescore criteria latest "state/prd-rescore/$p/" || return 1
    return 0
  fi
  rel=${f#"$root"/}
  if ! counts=$(jq -ce '(.criteria // .results) | arrays
      | map((.status // "") | tostring | ascii_downcase)
      | {partial: map(select(. == "partial")) | length,
         failed: map(select(. == "fail" or . == "failed")) | length,
         criteria: length}' "$f" 2>/dev/null); then
    _pmsa_err prd-rescore.partial prd-rescore criteria latest "$rel" || return 1
    return 0
  fi
  _pmsa_row prd-rescore.partial prd-rescore criteria "$(jq '.partial' <<<"$counts")" latest "$rel" ok || return 1
  _pmsa_row prd-rescore.failed prd-rescore criteria "$(jq '.failed' <<<"$counts")" latest "$rel" ok || return 1
  _pmsa_row prd-rescore.criteria prd-rescore criteria "$(jq '.criteria' <<<"$counts")" latest "$rel" ok || return 1
}
