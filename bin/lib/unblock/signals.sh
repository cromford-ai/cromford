#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/signals.sh — BH-8390 (UNB-7): what a red merge-queue batch
# says, and which member owns it. Sourced by collectors/queue.sh, never run;
# nothing runs on source. Pure jq: 0 network calls, 0 writes, 0 model calls.
#
#   ub_signals_classify [lines] < batch_failure JSON  > signals JSON array
#     [lines]: the failure lines kept per signal (the caller passes
#     UNBLOCK_SIGNAL_LINES; 8 when unset).
#     One signal per failed check (conclusion cancelled or timed_out is not a
#     cause and is skipped), from the check's failure lines:
#       reg    lanes-registry red on <lane>/<KNOB> (tests/lanes-registry-test.sh
#              section 7 "wired lanes read env knobs the registry does not
#              carry", section 8 "knobs with a bad schema", the bh-2205 C1
#              copy, prequeue-invariant lanes-registry). tokens: the KNOBs.
#       cat    worker-node R0 "real tree has offenders". tokens: the offender
#              suites the lines name (the tool keeps FAIL lines only, so this
#              is often empty and the member's patch decides).
#       map    mc-split-layout case 3 (misplaced / "defined by a module the
#              map does not assign"). tokens: the misplaced functions.
#       pdb    plan-diff-bind changed-not-planned <path>. tokens: the paths.
#       trace  `HIT <suite> ...` lines of the trace-safety harness. tokens:
#              the suite base names.
#       suite  any other check: tokens are the tests/*.sh paths its lines
#              name. No path = `decidable: false`.
#       unread a check whose lines were not read: decidable false.
#     Each: {class, check, tokens, decidable, lines (at most [lines]), and per
#     class: pairs [{lane, knob}] + section (reg), modules [{module, fn}] (map)}.
#
#   ub_signals_own <signals-file> <member-file> [brief-max] [lines]
#                                                > {owned, owns, signal,
#                                                  brief, trace_own_new}
#     Both are files (a diff's patches can pass the argv cap). member-file:
#     one JSON object {pr, draft, ticket, complete (bool), files: [{filename,
#     status, patch}] | null, culprit_checks: [check names the tool named
#     this PR a culprit for], reads: {<suite>: [member files its text names]}}.
#     A member owns a signal when the tool named it a culprit for that check,
#     or by class: reg a KNOB in a file name or an added patch line; cat an
#     offender suite in its files, or a tests/*.sh it adds or edits that loads
#     the worker (jobs/src/index.js, node --test) and never calls
#     worker_catalogs; map a misplaced function, or a function it defines in
#     bin/lib/mc/<m>.sh with no tests/mc/expected-map.d row in its diff; pdb a
#     named path in its files; trace a HIT suite in its files (by base name);
#     suite a named suite in its files, or a named suite whose text names one
#     of its files (the suite's inputs).
#     owns: true when it owns one signal; false only when its whole diff was
#     read and every signal is decidable; else null (unknown never matches).
#     signal: the first owned class in the order reg cat map pdb trace suite.
#     trace_own_new: true when every owned HIT suite is a file it ADDED,
#     false when one is not, null when it owns no trace signal.
#     brief: the fix, then the failing lines of the owned checks, at most
#     [brief-max] characters (UNBLOCK_BRIEF_MAX_CHARS; 1800 when unset); ""
#     when it owns nothing. The trace signal keeps the first 3 HIT lines: the
#     ticket's R-TRACE card names exactly 3.

_UB_SIG_CLASSIFY='
def strip: sub("^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.]+Z\\s?"; "") | gsub("\u001b\\[[0-9;]*m"; "");
def suites($L): [$L[] | scan("(?:^|[^A-Za-z0-9._/-])(tests/[A-Za-z0-9._/-]+\\.sh)") | .[0]] | unique;
[ .failed_checks[]? | select(type == "object")
  | select((.conclusion // "failure") | IN("cancelled", "timed_out") | not)
  | (.name // "?" | tostring) as $chk
  | if (.lines | type) != "array" then {class: "unread", check: $chk, tokens: [], decidable: false, lines: []}
    else [.lines[] | strings | strip] as $L
    | ([$L[] | select(test("wired lanes read env knobs|knobs with a bad schema|lanes-registry"))]) as $reg
    | ([$L[] | select(test("wired lanes read env knobs|knobs with a bad schema"))
        | [scan("(?:^|[\\s:])([a-z0-9_][a-z0-9._-]*)/([A-Z][A-Z0-9_]{2,})(?=$|[\\s,;])")] | .[]] | unique) as $pairs
    | if ($pairs | length) > 0 then
        {class: "reg", check: $chk, tokens: ($pairs | map(.[1]) | unique), decidable: true,
         pairs: ($pairs | map({lane: .[0], knob: .[1]})),
         section: ((if any($L[]; test("wired lanes read env knobs")) then ["7"] else [] end)
                   + (if any($L[]; test("knobs with a bad schema")) then ["8"] else [] end) | join("+")),
         lines: $reg[0:$nl]}
      elif any($L[]; test("real tree has offenders")) then
        {class: "cat", check: $chk, decidable: true, lines: [$L[] | select(test("offenders|tests/"))][0:$nl],
         tokens: [$L[] | select(test("real tree has offenders") | not)
                  | scan("^\\s*(tests/[A-Za-z0-9._/-]+\\.sh)(?=:|\\s*$)") | .[0]] | unique}
      elif any($L[]; test("misplaced: |defined by a module the map does not assign")) then
        ([$L[] | scan("misplaced: ([A-Za-z_][A-Za-z0-9_]*) is defined by mc/([A-Za-z0-9._-]+)\\.sh") | {fn: .[0], module: .[1]}] | unique) as $mods
        | {class: "map", check: $chk, decidable: true, tokens: ($mods | map(.fn)), modules: $mods,
           lines: [$L[] | select(test("misplaced|map does not assign"))][0:$nl]}
      elif any($L[]; test("changed-not-planned ")) then
        {class: "pdb", check: $chk, decidable: true,
         tokens: ([$L[] | scan("changed-not-planned ([^\\s]+)") | .[0]] | unique),
         plan: ([$L[] | scan("changed-not-planned [^\\s]+ ([^\\s]+plan\\.md)") | .[0]] | first // null),
         lines: [$L[] | select(test("changed-not-planned"))][0:$nl]}
      elif any($L[]; test("(^|\\s)HIT [^\\s]+")) then
        ([$L[] | select(test("(^|\\s)HIT [^\\s]+"))]) as $hits
        | {class: "trace", check: $chk, decidable: true, hits: ($hits | length),
           tokens: ([$hits[] | scan("(?:^|\\s)HIT ([^\\s]+)") | .[0] | sub("^.*/"; "")] | unique),
           lines: $hits[0:3]}
      else
        suites($L) as $s
        | {class: "suite", check: $chk, tokens: $s, decidable: (($s | length) > 0), lines: $L[0:$nl]}
      end
    end ]'

ub_signals_classify() { jq -c --argjson nl "${1:-8}" "$_UB_SIG_CLASSIFY"; }

_UB_SIG_OWN='
def added($f): ($f.patch // "") | split("\n") | map(select(startswith("+") and (startswith("+++") | not)) | .[1:]);
def base: sub("^.*/"; "");
($m.files // null) as $F
| ($F != null and $m.complete == true) as $full
| ($F // []) as $FF
| ($FF | map(.filename)) as $names
| ([$FF[] | added(.)[]]) as $plus
| ([$FF[] | select(.filename | test("\\.md$") | not)]) as $code
| def word($k): test("(^|[^A-Za-z0-9_])" + $k + "([^A-Za-z0-9_]|$)");
  def owns_reg($s): any($s.tokens[]; . as $k
    | any($code[]; (.filename | word($k)) or any(added(.)[]; word($k))));
  def cat_suites: [$FF[] | select((.filename | test("^tests/(mc/)?[^/]+\\.sh$")) and (.status != "removed"))
                   | select(any(added(.)[]; test("jobs/src/index\\.js|(^|[^A-Za-z0-9_-])node[[:space:]].*--test")))
                   | select(((.patch // "") | test("worker_catalogs|llm-sites-build\\.sh.*--compose")) | not) | .filename];
  def map_fns: [$FF[] | select(.filename | test("^bin/lib/mc/[^/]+\\.sh$")) | (.filename | base | sub("\\.sh$"; "")) as $mod
                | added(.)[] | scan("^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*\\(\\)") | {module: $mod, fn: .[0]}]
                | map(select(.fn as $fn | ([$FF[] | select(.filename | startswith("tests/mc/expected-map.d/")) | added(.)[]
                                            | select(split("\t") | .[1] == $fn)] | length) == 0));
  def hit($s):
    if any(($m.culprit_checks // [])[]; . == $s.check) then true
    elif $s.class == "reg" then owns_reg($s)
    elif $s.class == "cat" then (any($s.tokens[]; . as $t | any($names[]; . == $t)) or (cat_suites | length) > 0)
    elif $s.class == "map" then (any($s.tokens[]; . as $fn | any(map_fns[]; .fn == $fn)) or (map_fns | length) > 0)
    elif $s.class == "pdb" then any($s.tokens[]; . as $t | any($names[]; . == $t))
    elif $s.class == "trace" then any($s.tokens[]; . as $t | any($names[]; base == $t))
    elif $s.class == "suite" then any($s.tokens[]; . as $t | any($names[]; . == $t) or ((($m.reads // {})[$t] // []) | length) > 0)
    else false end;
  ([$sig[] | select(hit(.))]) as $own
  | (["reg", "cat", "map", "pdb", "trace", "suite"] | map(. as $c | select(any($own[]; .class == $c))) | first // null) as $primary
  | ($m.ticket // "<TICKET>") as $tk
  | def fix($s):
      if $s.class == "reg" then
        ($s.pairs | map("\(.lane)/\(.knob)") | join(", ")) as $p
        | "tests/lanes-registry-test.sh is red (section \($s.section)) on \($p). "
          + (if ($s.section | test("8")) then "Section 8: in catalog/lanes.d/<lane>.knobs.d/<KNOB>.json (or the knob row in catalog/lanes.d/<lane>.json) set zero_means to null, \"off\" or \"unlimited\" and move any prose into note. " else "" end)
          + (if ($s.section | test("7")) then "Section 7: the lane reads the env knob but has no row: add catalog/lanes.d/<lane>.knobs.d/<KNOB>.json with env, type, default, zero_means null, note, read_in (the file that reads it) and settable (false for plumbing). " else "" end)
          + "Then run HARNESS_TEST_SANDBOX=1 bash tests/lanes-registry-test.sh."
      elif $s.class == "cat" then
        ((($s.tokens + cat_suites) | unique) as $o
         | "worker-node R0: \(if ($o | length) > 0 then ($o | join(", ")) else "a suite this PR adds" end) loads the worker without writing the catalogs. Add these two lines right after DIR= in each: . \"$DIR/tests/lib/worker-catalogs.sh\" || exit 1   and   worker_catalogs \"$DIR\" || exit 1. Then run tests/worker-node-lanes-build.bh-6540-test.sh and tests/worker-node-catalog-compose.bh-6452-test.sh.")
      elif $s.class == "map" then
        ((($s.modules // []) + map_fns) | unique) as $mf
        | "tests/mc-split-layout-test.sh case 3: \(if ($mf | length) > 0 then ($mf | map("\(.fn) is defined by bin/lib/mc/\(.module).sh") | join(", ")) else "a function this PR adds to bin/lib/mc/" end) and no expected-map row assigns it. Add tests/mc/expected-map.d/\($tk).tsv with one row per function: \(if ($mf | length) > 0 then ($mf | map("\(.module)<TAB>\(.fn)<TAB>lib") | join("; ")) else "<module><TAB><fn><TAB>lib" end)."
      elif $s.class == "pdb" then
        "plan-diff-bind: changed-not-planned \($s.tokens | join(", ")). Name each path in \($s.plan // ".harness/specs/\($tk)/plan.md") under ## Files to touch (a test under ## Tests that must change). If the path is another ticket'"'"'s test, also add a line TEST-CHANGE: <path> <why> to the PR body."
      elif $s.class == "trace" then
        "Tests cannot touch a real harness: \($s.hits) HIT line(s) from \($s.tokens | join(", ")). Make the suite write only under its scratch dir (tests/lib/scratch.sh) and read no live /root/harness path."
      else
        "The merge-queue batch #\($m.draft // "?") ran \($s.tokens | join(", ")) red (check \($s.check)). Merge origin/main, run HARNESS_TEST_SANDBOX=1 bash on each, and fix this PR'"'"'s change. Do not weaken the suite."
      end;
  {owned: [$own[] | .class] | unique,
   signal: $primary,
   owns: (if ($own | length) > 0 then true
          elif $full and ($sig | length) > 0 and all($sig[]; .decidable == true) then false
          else null end),
   trace_own_new: ([$own[] | select(.class == "trace")] as $t
     | if ($t | length) == 0 then null
       else all($t[].tokens[]; . as $b | any($FF[]; (.filename | base) == $b and .status == "added")) end),
   brief: (if ($own | length) == 0 then ""
           else ([$own[] | fix(.)] | unique | join(" ")) + " Failing lines: " + ([$own[] | .lines[]] | unique | .[0:$nl] | join(" | "))
           end | .[0:$bmax])}'

ub_signals_own() { jq -nc --slurpfile sig "$1" --slurpfile m "$2" --argjson nl "${4:-8}" --argjson bmax "${3:-1800}" '($sig[0]) as $sig | ($m[0]) as $m | '"$_UB_SIG_OWN"; }
