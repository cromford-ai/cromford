#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/rules.sh — the unblock agent's rule engine (BH-7723, UNB-1).
# Sourced, never run; nothing runs on source.
#
# A pure function. It reads the rule files and stall records, and it prints
# decisions. It makes 0 network calls, 0 writes and 0 model calls (G4). The
# ledger claim and every real action belong to the tick and the act layer.
#
#   ub_rules_load [dir]
#     dir defaults to $HARNESS/catalog/unblock-rules.d. Reads every *.json whose
#     name does not start with `_`, and prints the rules as one JSON array,
#     sorted by priority, then id. Each rule comes out with action.name set
#     (a file may write action.verb, as U8-U12 do; it is read as action.name).
#     rc 2 refuses the WHOLE load (one stderr line per problem, nothing on
#     stdout) when a file is not a JSON object, two files carry one id, the id
#     does not match _schema.json's pattern, a required key is missing or has
#     the wrong type, a cite is not a key of the cites file, a predicate does
#     not compile or uses a word that reads outside the record (input, env,
#     now, halt, debug, ...), or the cites file is missing or unreadable. The
#     cites file is ${UNBLOCK_CITES_FILE:-<dir>/_cites.json}.
#     Required keys (catalog/unblock-rules.d/_schema.json): id, priority
#     (integer), family, class, cites (non-empty array), match.kind (a kind, a
#     non-empty array of kinds, or "*" for any kind), match.all (an array of jq
#     predicates; empty matches every record of the kind), action.name (or
#     action.verb, not both), key (non-empty array of record field paths; the
#     word `id` is the rule id). Optional: action.args (an object; a string
#     value that starts with `.` is a record field path), judge null or
#     {prompt, question, when?} (no `when` = the judge always runs),
#     never_auto {<key glob>: <class>} (the class when .proposal.key matches),
#     note and any other key the engine does not read.
#     The id is not required to be the file stem: main's U8-U12 files are
#     U8-box-restart.json with id "U8". Every lookup indexes by id
#     (bin/lib/unblock/override.sh uo_class_of, which
#     bin/staff/tackler-report.sh calls), never by <rule_id>.json (BH-8418).
#
#   ub_rules_eval [dir]  < stall JSONL  > decision JSONL
#     Each predicate reads T (true), F (false) or U (unknown: an error, a
#     non-boolean, or not exactly one output). Unknown is not false, and it is
#     not true: a rule matches only when its match.kind takes the record's kind
#     and EVERY predicate reads T. The first match by priority wins.
#     Every decision carries the bin/unblock.sh seam shape:
#       {decision_key, project, repo, subject_kind, subject, pr, head,
#        stall_class (the record's kind), stall_kind, rule_id, cites, class,
#        decision, action: {name, args} | null, judge, evidence (the record)}
#     act:      a matched rule whose action is not `card`. Also family and
#               would ("WOULD_<ACTION>"). judge is null when the rule has none
#               or its `when` reads F; with `when` U it carries
#               when_unknown:true, so the act layer runs the judge.
#     escalate: a matched rule whose action is `card` (U12, the fallback):
#               rule_id, cites, class and action from the rule, reason, and
#               near_misses [{rule, failed, unknown}] (the rules of the
#               record's kind that did not match). With no match at all, or a
#               match that cannot be keyed: rule_id null, action null, reason
#               "no rule matched", "key field <f> is null" or "unparseable
#               stall record".
#     class: the rule's class, or the never_auto class whose glob
#     (case-insensitive) matches .proposal.key.
#     decision_key is the sha256 of the rule's key field values and the rule
#     id, joined by U+001F; an unkeyed escalation keys on repo, subject, head,
#     kind and "U12". No timestamp and no counter, so a second tick over the
#     same stalls makes the same keys (the ledger's UNIQUE decision_key is the
#     dedup).
#     rc 2 and no decision when the load is refused.
#
#   ub_rules_would_lines  < decision JSONL
#     One line per act decision:
#     WOULD_<ACTION> <rule_id> <subject> <head12> key=<key12> cites=<G..>
#
# NO ROOT DEFAULT (D43): with no dir and neither $HARNESS nor $H, rc 2.

_ub_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# Words a predicate must not use: each one reads something other than the
# record (another input, the environment, the clock) or stops the program.
_UB_FORBIDDEN='(^|[^A-Za-z0-9_$])(input|inputs|input_filename|input_line_number|env|now|halt|halt_error|debug|stderr|import|include|def|\$ENV|\$__loc__|\$__prog_args)([^A-Za-z0-9_]|$)'

_ub_validate_jq='
def str: type == "string" and length > 0;
def fpath: type == "string" and test("^[a-z_][a-z0-9_]*(\\.[a-z_][a-z0-9_]*)*$");
def argpath: type == "string" and test("^\\.[a-z_][a-z0-9_]*(\\.[a-z_][a-z0-9_]*)*$");
def kinds: if type == "string" then [.] elif type == "array" then . else null end;
if type != "object" then "not a JSON object" else
  (if (.id | type) == "string" and (.id | test("^U[0-9A-Za-z][A-Za-z0-9._-]{0,63}$")) then empty
   else "id \(.id | tojson) does not match ^U[0-9A-Za-z][A-Za-z0-9._-]{0,63}$" end),
  (if (.priority | type) != "number" or (.priority | floor) != .priority then "priority is not an integer" else empty end),
  (if (.family | str) then empty else "family is missing" end),
  (if (.class | str) then empty else "class is missing" end),
  (if (.cites | type) != "array" or (.cites | length) == 0 then "cites must be a non-empty array"
   else .cites[] as $g | if ($g | str | not) then "cite \($g | tojson) is not a string"
                         elif ($c | has($g)) then empty else "cite \($g) is not in the cites file" end end),
  (if (.match | type) != "object" or (.match.kind | kinds) == null or (.match.kind | kinds | length) == 0
      or (.match.kind | kinds | all(str) | not) then "match.kind is missing" else empty end),
  (if (.match.all | type) != "array" or (.match.all | all(str) | not)
   then "match.all must be an array of predicates" else empty end),
  (if (.action | type) != "object" then "action is missing"
   elif (.action | has("name")) and (.action | has("verb")) then "action has both name and verb"
   elif ((.action.name // .action.verb) | type == "string" and test("^[a-z_]{1,40}$") | not) then "action.name is missing"
   else empty end),
  (if (.action.args // {} | type) != "object" then "action.args is not an object"
   else (.action.args // {} | to_entries[] | select((.value | type) == "string" and (.value | startswith(".")) and (.value | argpath | not))
         | "action.args.\(.key) \(.value | tojson) is not a field path") end),
  (if (.key | type) != "array" or (.key | length) == 0 or (.key | all(fpath) | not)
   then "key must be a non-empty array of field paths" else empty end),
  (if .judge == null then empty
   elif (.judge | type) != "object" or (.judge.prompt | str | not) or (.judge.question | str | not)
        or ((.judge | has("when")) and (.judge.when | str | not))
   then "judge needs prompt and question (when, if set, is a predicate)" else empty end),
  (if (.never_auto // {} | type) != "object" or (.never_auto // {} | all(.[]; str) | not)
   then "never_auto must map key globs to classes" else empty end)
end'

ub_rules_load() {
  local dir="${1:-}" h cites f stem bad=0 line p dup
  local -a ok=()
  if [ -z "$dir" ]; then
    h=$(_ub_root)
    [ -n "$h" ] || { echo "ub_rules_load: no rules dir and no HARNESS" >&2; return 2; }
    dir="$h/catalog/unblock-rules.d"
  fi
  [ -d "$dir" ] || { echo "ub_rules_load: no rules dir $dir" >&2; return 2; }
  cites="${UNBLOCK_CITES_FILE:-$dir/_cites.json}"
  jq -e 'type == "object"' "$cites" >/dev/null 2>&1 \
    || { echo "ub_rules_load: cites file $cites is missing or not a JSON object; every rule refused" >&2; return 2; }
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    stem=$(basename "$f" .json)
    case "$stem" in _*) continue ;; esac
    if ! jq -e . "$f" >/dev/null 2>&1; then echo "ub_rules_load: $stem: not valid JSON" >&2; bad=1; continue; fi
    line=$(jq -r --slurpfile c "$cites" '($c[0]) as $c | '"$_ub_validate_jq" "$f")
    if [ -n "$line" ]; then
      while IFS= read -r p; do echo "ub_rules_load: $stem: $p" >&2; done <<< "$line"
      bad=1; continue
    fi
    while IFS= read -r p; do
      if [[ "$p" =~ $_UB_FORBIDDEN ]]; then
        echo "ub_rules_load: $stem: predicate $p reads outside the record (${BASH_REMATCH[2]})" >&2; bad=1
      elif ! jq -n "def _ub_p: $p; null" >/dev/null 2>&1; then
        echo "ub_rules_load: $stem: predicate $p does not compile" >&2; bad=1
      fi
    done < <(jq -r '.match.all[], (.judge.when // empty)' "$f")
    ok+=("$f")
  done
  if [ "${#ok[@]}" -gt 0 ]; then
    dup=$(jq -rs '[.[].id] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "${ok[@]}")
    if [ -n "$dup" ]; then
      while IFS= read -r p; do echo "ub_rules_load: id $p is carried by more than one file" >&2; done <<< "$dup"
      bad=1
    fi
  fi
  [ "$bad" = 0 ] || return 2
  if [ "${#ok[@]}" -eq 0 ]; then printf '[]\n'; return 0; fi
  jq -cs 'map(.action = ({name: (.action.name // .action.verb)} + (if .action | has("args") then {args: .action.args} else {} end))
             | .match.kind = (.match.kind | if type == "string" then [.] else . end))
          | sort_by(.priority, .id)' "${ok[@]}"
}

# The jq program for one rule set: one def per rule that maps the record to a
# T/F/U array (one entry per predicate), one def for its judge `when`, and a
# dispatch by index. Built by jq from the rule array, never by hand.
_ub_program() { # _ub_program <rules json>
  jq -r '
    def tri($p): "([try ((\($p)) | if . == true then \"T\" elif . == false then \"F\" else \"U\" end) catch \"U\"] | if length == 1 then .[0] else \"U\" end)";
    (to_entries | map("def _ub_r\(.key): [\(.value.match.all | map(tri(.)) | join(", "))];\ndef _ub_w\(.key): \(tri(.value.judge.when // "true"));") | join("\n")),
    "def _ub_d($i): if false then null \(to_entries | map("elif $i == \(.key) then {res: _ub_r\(.key), when: _ub_w\(.key)}") | join(" ")) else {res: [\"U\"], when: \"U\"} end;"
  ' <<< "$1"
}

_ub_main='
def esc_km($r): [$r.repo, $r.subject, $r.head, $r.kind] | map(. // "" | tostring) + ["U12"] | join("\u001f");
def base($r): {project: $r.project, repo: $r.repo,
  subject_kind: ($r.subject_kind // (if ($r.pr | type) == "number" then "pr" else null end)),
  subject: $r.subject, pr: $r.pr, head: $r.head, stall_class: $r.kind, stall_kind: $r.kind, evidence: $r};
def unkeyed($r; $reason; $nm): base($r) + {decision: "escalate", rule_id: null, cites: [], class: "escalate",
  action: null, judge: null, reason: $reason, near_misses: $nm,
  inputs_unreadable: ($r.inputs_unreadable // []), _km: esc_km($r)};
def misses($tried): [$tried[] | select(.res | all(. == "T") | not) | .r as $x | .res as $res
  | {rule: $x.id,
     failed:  [range(0; $res | length) as $j | select($res[$j] == "F") | $x.match.all[$j]],
     unknown: [range(0; $res | length) as $j | select($res[$j] == "U") | $x.match.all[$j]]}];
def glob($g): "^" + ($g | ascii_upcase | split("*") | map(gsub("[^A-Z0-9_]"; ".")) | join(".*")) + "$";
def klass($r; $rec): ($rec.proposal.key? // "" | tostring | ascii_upcase) as $k
  | ([($r.never_auto // {}) | to_entries[] | select(.key as $g | $k != "" and ($k | test(glob($g)))) | .value] | first) // $r.class;
(try fromjson catch null) as $rec
| if ($rec | type) != "object" then
    {decision: "escalate", rule_id: null, cites: [], class: "escalate", action: null, judge: null,
     reason: "unparseable stall record", near_misses: [], evidence: {unparseable: .},
     _km: ([., "U12"] | join("\u001f")), project: null, repo: null, subject_kind: null, subject: null,
     pr: null, head: null, stall_class: null, stall_kind: null}
  else
    [$R | to_entries[] | select(.value.match.kind | index($rec.kind) != null or index("*") != null)
      | .key as $i | ($rec | _ub_d($i)) as $d
      | {r: .value, res: $d.res, when: $d.when}] as $tried
    | (first($tried[] | select(.res | all(. == "T"))) // null) as $m
    | if $m == null then unkeyed($rec; "no rule matched"; misses($tried))
      else
        $m.r as $r
        | ($r.key | map(. as $k | {k: $k, v: (if $k == "id" then $r.id else ($rec | getpath($k | split("."))) end)})) as $kv
        | ([$kv[] | select(.v == null) | .k] | first // null) as $nullk
        | if $nullk != null then
            unkeyed($rec; "key field \($nullk) is null"; []) + {matched_rule: $r.id}
          else
            {name: $r.action.name,
             args: (($r.action.args // {}) | map_values(if type == "string" and startswith(".")
                      then (. as $p | $rec | getpath($p | ltrimstr(".") | split("."))) else . end))} as $act
            | base($rec) + {rule_id: $r.id, cites: $r.cites, class: klass($r; $rec), family: $r.family, action: $act,
                _km: ([$kv[] | .v | tostring] + [$r.id] | join("\u001f"))}
            + (if $r.action.name == "card" then
                 {decision: "escalate", judge: null,
                  reason: (if ($r.match.kind | index("*")) != null then "no rule matched" else "rule \($r.id) escalates" end),
                  near_misses: misses($tried), inputs_unreadable: ($rec.inputs_unreadable // [])}
               else
                 {decision: "act", would: ("WOULD_" + ($r.action.name | ascii_upcase)),
                  judge: (if $r.judge == null or $m.when == "F" then null
                          else {prompt: $r.judge.prompt, question: $r.judge.question}
                               + (if $m.when == "U" then {when_unknown: true} else {} end) end)}
               end)
          end
      end
  end'

ub_rules_eval() {
  local rules prog line km k
  rules=$(ub_rules_load "${1:-}") || return 2
  prog="$(_ub_program "$rules")"$'\n'"$_ub_main" || return 2
  jq -cR --argjson R "$rules" "$prog" | while IFS= read -r line; do
    km=$(jq -r '._km' <<< "$line")
    k=$(printf '%s' "$km" | sha256sum | cut -d' ' -f1)
    jq -c --arg k "$k" 'del(._km) | .decision_key = $k' <<< "$line"
  done
}

ub_rules_would_lines() {
  jq -rR '(try fromjson catch null) | select(type == "object" and .decision == "act")
    | "\(.would) \(.rule_id) \(.subject) \((.head // "") | .[0:12]) key=\(.decision_key[0:12]) cites=\(.cites | join(","))"'
}
