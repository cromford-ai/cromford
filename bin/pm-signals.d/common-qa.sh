# shellcheck shell=bash
# pm-signals adapter: open QA findings by severity for the project (BH-7259).
# Ledgers: every *.jsonl under $HARNESS/state/ (depth 3 at most) whose path
# below state/ contains "qa", modified inside 30 days of now. That covers the
# group-findings ledgers (bin/lib/group-findings.sh: findings-ledger.jsonl and
# qa-findings.jsonl) and any walkthrough ledger with the same row shape.
# A row is the project's when .board or .project is the project exactly. Its key
# is .fp // .id // .title, and the LAST row of a key wins (files are read
# oldest mtime first): the ledgers only grow, so the last row is the state.
# Closed: the last .status (or .state) is closed, fixed, resolved, wontfix, done
# or dismissed (any case). Every other value, absent and empty included, is
# open. The group-findings .action (filed, commented...) never closes a finding.
# A line that is not JSON is skipped.
# Severity: critical, high, medium or low (lowercased); anything else is medium.
# Rows qa.open_<severity>, metric open_findings, window 30d, link: the newest
# matched ledger. No ledger with a row for the project = one qa.open
# not-configured row: a missing ledger is not evidence of zero findings.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/pm-signals-adapter.sh" || return 1
pms_qa() {
  local p="$1" root now cut files=() hit=() f t newest="" counts s
  root=$(_pmsa_root); now=$(_pmsa_now); cut=$((now - 30*86400))
  if [ -n "$root" ] && [ -d "$root/state" ]; then
    while read -r t f; do
      [ "${t%.*}" -ge "$cut" ] 2>/dev/null && files+=("$f")
    done < <(find "$root/state" -maxdepth 3 -type f -name '*.jsonl' -path "$root/state/*qa*" -printf '%T@ %p\n' 2>/dev/null | sort -n)
  fi
  for f in ${files[@]+"${files[@]}"}; do
    jq -nRe --arg p "$p" 'any(inputs | fromjson? | objects; .board == $p or .project == $p)' "$f" >/dev/null 2>&1 \
      && { hit+=("$f"); newest=$f; }
  done
  if [ "${#hit[@]}" = 0 ]; then
    _pmsa_nc qa.open qa open_findings 30d state/ || return 1
    return 0
  fi
  counts=$(jq -nRc --arg p "$p" '
    reduce (inputs | fromjson? | objects | select(.board == $p or .project == $p)) as $r ({};
      .[($r.fp // $r.id // $r.title // "" | tostring)] = $r)
    | [.[] | select(((.status // .state // "") | tostring | ascii_downcase)
                    | IN("closed", "fixed", "resolved", "wontfix", "done", "dismissed") | not)
           | ((.severity // "") | tostring | ascii_downcase)
           | if IN("critical", "high", "medium", "low") then . else "medium" end]
    | {critical: (map(select(. == "critical")) | length), high: (map(select(. == "high")) | length),
       medium: (map(select(. == "medium")) | length), low: (map(select(. == "low")) | length)}' \
    "${hit[@]}" 2>/dev/null) || return 1
  for s in critical high medium low; do
    _pmsa_row "qa.open_$s" qa open_findings "$(jq -c --arg s "$s" '.[$s]' <<<"$counts")" 30d "${newest#"$root"/}" ok || return 1
  done
}
