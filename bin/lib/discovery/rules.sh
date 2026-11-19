#!/bin/bash
# bin/lib/discovery/rules.sh — BH-9795: the questions and the decision table
# of the discovery-daily lane, in ONE file. The model answers the questions; it
# never gives a verdict. This table decides.
#
#   dd_rules_questions                   the questions, as prompt text
#   dd_rules_decide <reply> <cands>      prints ONE of:
#       ticket | comment <n> | noise known-benign | noise not-own-code | invalid
#     <reply> is the model's JSON object {answers: {...}, draft: {...}};
#     <cands> is the JSON array of the candidate ticket numbers.
#
# Answers are trimmed and lowercased once. Rules, first match wins:
#   1. a missing or off-type answer                 -> invalid
#   2. known_benign = yes                           -> noise known-benign
#   3. same_ticket > 0 and one of the candidates    -> comment <same_ticket>
#   4. own_code = no and user_impact != yes         -> noise not-own-code
#   5. draft.title or draft.cause empty             -> invalid
#   6. otherwise                                    -> ticket
# A same_ticket that is not a candidate reads as 0: the model cannot pick a
# ticket outside the list. Any other key of the reply (a "verdict") is ignored.

dd_rules_questions() {
  cat <<'Q'
Answer each question in the `answers` object:
- known_benign (yes|no): Is this a known harmless class: a client network abort, a cancelled request, a browser extension, a bot or crawler, or an expected 4xx answer?
- user_impact (yes|no|unknown): Does a user of the product see a failure: an error page, a failed save, a lost write or a broken flow?
- own_code (yes|no|unknown): Is the top in-app frame in this project's own code, not a vendor SDK or a third-party script?
- same_ticket (integer): Which candidate ticket number describes the same problem? 0 when none.
Then write the `draft` object: title, cause, evidence, proposed_fix, acceptance_tests (a list).
Q
}

dd_rules_decide() {
  local reply=$1 cands=${2:-[]} out
  out=$(jq -r --argjson c "$cands" '
    def norm: if type == "string" then (gsub("^\\s+|\\s+$"; "") | ascii_downcase) else . end;
    def text: (. // "") | if type == "string" then gsub("^\\s+|\\s+$"; "") else "" end;
    if type != "object" or (.answers | type) != "object" then "invalid"
    else
      (.answers.known_benign | norm) as $kb | (.answers.user_impact | norm) as $ui
      | (.answers.own_code | norm) as $oc | .answers.same_ticket as $st
      | if ($kb | IN("yes", "no") | not) or ($ui | IN("yes", "no", "unknown") | not)
           or ($oc | IN("yes", "no", "unknown") | not)
           or ($st | type) != "number" or $st < 0 or $st != ($st | floor) then "invalid"
        elif $kb == "yes" then "noise known-benign"
        elif $st > 0 and ($c | index($st)) != null then "comment \($st)"
        elif $oc == "no" and $ui != "yes" then "noise not-own-code"
        elif (.draft | type) != "object" or (.draft.title | text) == "" or (.draft.cause | text) == "" then "invalid"
        else "ticket" end
    end' <<<"$reply" 2>/dev/null) || out=invalid
  printf '%s\n' "${out:-invalid}"
}
