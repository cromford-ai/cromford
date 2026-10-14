#!/bin/bash
# tests/gh-passthrough-budget.bh-791-test.sh — the pass-through BUDGET and the
# census SUBSET RATCHET for bin/gh-rest-shim (#769 chunk 5, BH-791).
#
# WHAT IT PINS, in one sentence: every `gh pr|issue|run|repo` form the harness
# really writes is translated to REST, and a NEW subcommand cannot enter the
# harness without first entering the census where the shim must prove it
# translates it.
#
# HOW IT DRIVES. tests/fixtures/gh-shim-census.txt holds one gh argv per line.
# Each line runs through the REAL bin/gh-rest-shim with the REAL shipped
# bin/lib/gh-shim/*.sh handlers (GH_SHIM_LIB stays unset), over
# tests/lib/gh-shim-stub.sh's file-replaying stub. Nothing here greps handler
# source: every assertion reads an artifact — $T/h/logs/gh-passthrough.log,
# $T/gh-calls.txt, $T/gh-env.txt, $T/git-calls.txt, $RC and $ERR.
#
# THE FOUR PER-LINE ASSERTIONS:
#   budget      the pass-through log is EMPTY (the headline claim)
#   translated  at least one `api ` call was recorded — an empty log proves
#               nothing if the shim answered without calling anything
#   no-404      $ERR carries no HTTP 404, which is what forces the fixture set
#               below to be complete
#   passthru-logged   for the two `!` lines only: exactly one log line, and
#               gshim_env shows depth=1, the only marker that separates "the
#               shim handed this through" from "the call never met the shim"
#
# THE TWO `!` LINES. `gh pr checks --watch` (bin/hotfix-migrate.sh:72) and
# `gh run watch --exit-status` (bin/lib/hotfix-migrate-workflow.sh:342) are live
# callers that no single REST call replaces — a long-poll watch is not one
# request. They stay in the census because the subset ratchet reads that file as
# the whole set of verbs the harness may call, and they assert the OPPOSITE of
# the budget: they must log, loudly, every time.
#
# MUTATION CHECKS (D1), the three at the bottom, each against a COPY of the
# census under $T and never against the repo file:
#   1. drop the `!` from `pr checks`   -> the budget block must go red
#   2. delete the `pr merge` line      -> the subset block must go red
#   3. point the scanner at an empty dir -> the non-empty guard must go red
#
# NO CLOCK, NO DICE, NO SLEEP: every fixture timestamp is a literal.
#
# Run from anywhere:  bash tests/gh-passthrough-budget.bh-791-test.sh (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-shim-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CENSUS="$DIR/tests/fixtures/gh-shim-census.txt"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }

if [ ! -f "$CENSUS" ]; then
  echo "FAIL: the census $CENSUS does not exist"
  echo "gh-passthrough-budget: 0 passed, 1 failed"
  exit 1
fi

gshim_stub_setup
logfile="$T/h/logs/gh-passthrough.log"
logline() { [ -f "$logfile" ] && cat "$logfile"; return 0; }
gitcalls() { [ -f "$T/git-calls.txt" ] && cat "$T/git-calls.txt"; return 0; }

# The two constants every derived fixture key is built from. A second literal
# would let the check-runs fixture drift away from the head sha it answers for.
HEADSHA=feedfacecafe0001
JID=7001

# A local `git`, AHEAD of the stub's own. tests/lib/gh-shim-stub.sh is off
# limits for this ticket and its git stub answers only `remote get-url`, so a
# branch-resolving read path would get nothing back and pass through as
# flag:--head — a stub artifact that reads like a shim defect. Everything else
# execs the shared stub, so `repo clone` still records into $T/git-calls.txt.
mkdir -p "$T/gitshim"
{ printf '#!/bin/bash\nT=%q\n' "$T"
  cat <<'GITSTUB'
if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--abbrev-ref" ]; then
  echo feature; exit 0
fi
if [ "${1:-}" = "symbolic-ref" ]; then
  echo feature; exit 0
fi
exec "$T/real/git" "$@"
GITSTUB
} >"$T/gitshim/git"
chmod 755 "$T/gitshim/git"
export PATH="$T/gitshim:$PATH"

BODYFILE="$T/body.txt"
printf 'body from a file\n' >"$BODYFILE"
CLONEDIR="$T/clone-target"

# ── the fixture set ──────────────────────────────────────────────────────────
# Seeds every endpoint the census reaches, so no line can earn a 404 and no
# line can reach a green budget by answering nothing. Rows are deliberately
# SHORT — well under per_page — so gshim_paginate terminates on the first page.
census_fixtures_read() {
  gshim_fixture repos_o_r <<'J'
{"id":1,"name":"r","full_name":"o/r","default_branch":"main","archived":false,
 "html_url":"https://github.com/o/r","private":true,"description":"the repo"}
J
  gshim_fixture repos_o_r_pulls_1 <<J
{"number":1,"node_id":"PR_kwn1","html_url":"https://github.com/o/r/pull/1",
 "title":"Title","body":"Body text","state":"open","merged_at":null,"merged":false,
 "merge_commit_sha":"abc123","mergeable":true,"mergeable_state":"clean","draft":false,
 "created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-02T00:00:00Z","closed_at":null,
 "additions":10,"deletions":2,"changed_files":3,
 "head":{"ref":"feature","sha":"$HEADSHA","repo":{"full_name":"o/r"}},
 "base":{"ref":"main","repo":{"full_name":"o/r"}},
 "user":{"login":"operator","type":"User"},"merged_by":null,
 "labels":[{"node_id":"LA_1","name":"ai-build","description":"d","color":"ff0000"}],
 "assignees":[],"milestone":null}
J
  cat >"$T/fixtures/repos_o_r_pulls_1.diff" <<'D'
diff --git a/bin/x.sh b/bin/x.sh
--- a/bin/x.sh
+++ b/bin/x.sh
@@ -1 +1 @@
-old
+new
D
  gshim_fixture repos_o_r_pulls <<J
[{"number":1,"node_id":"PR_kwn1","html_url":"https://github.com/o/r/pull/1",
  "title":"Title","body":"Body","state":"open","merged_at":null,"draft":false,
  "created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-02T00:00:00Z","closed_at":null,
  "head":{"ref":"feature","sha":"$HEADSHA","repo":{"full_name":"o/r"}},
  "base":{"ref":"main","repo":{"full_name":"o/r"}},
  "user":{"login":"example-org-bot[bot]","type":"Bot"},
  "labels":[{"node_id":"LA_1","name":"ai-build","description":"d","color":"ff0000"}]},
 {"number":2,"node_id":"PR_kwn2","html_url":"https://github.com/o/r/pull/2",
  "title":"Second","body":"Body","state":"closed","merged_at":"2026-09-03T00:00:00Z","draft":false,
  "created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-03T00:00:00Z","closed_at":"2026-09-03T00:00:00Z",
  "head":{"ref":"feature-2","sha":"$HEADSHA","repo":{"full_name":"o/r"}},
  "base":{"ref":"main","repo":{"full_name":"o/r"}},
  "user":{"login":"operator","type":"User"},
  "labels":[{"node_id":"LA_1","name":"ai-build","description":"d","color":"ff0000"}]}]
J
  gshim_fixture repos_o_r_pulls_1_files <<'J'
[{"filename":"bin/x.sh","additions":3,"deletions":1,"status":"modified"}]
J
  gshim_fixture repos_o_r_pulls_1_reviews <<'J'
[{"node_id":"PRR_1","user":{"login":"operator","type":"User"},"body":"ok",
  "state":"APPROVED","submitted_at":"2026-09-02T00:00:00Z","commit_id":"abc123"}]
J
  gshim_fixture repos_o_r_pulls_1_commits <<'J'
[{"sha":"abc123","author":{"login":"operator"},
  "commit":{"message":"headline\n\nbody","committer":{"date":"2026-09-01T00:00:00Z"},
            "author":{"name":"the operator","email":"operator@example.com"}}}]
J
  # The PUT answer carries no title, the way REST's own merge response does not:
  # the handler's fallback GET is part of what this census drives.
  gshim_fixture repos_o_r_pulls_1_merge <<'J'
{"sha":"abc123","merged":true,"message":"Pull Request successfully merged"}
J
  gshim_fixture "repos_o_r_commits_${HEADSHA}_check-runs" <<'J'
{"total_count":1,"check_runs":[{"name":"harness-ci","status":"completed",
  "conclusion":"success","started_at":"2026-09-02T00:00:00Z",
  "completed_at":"2026-09-02T00:10:00Z","details_url":"https://github.com/o/r/runs/1"}]}
J
  gshim_fixture "repos_o_r_commits_${HEADSHA}_status" <<'J'
{"state":"success","statuses":[{"context":"ci/legacy","state":"success",
  "target_url":"https://example.invalid/1","created_at":"2026-09-02T00:00:00Z"}]}
J
  gshim_fixture repos_o_r_issues_1 <<'J'
{"number":1,"node_id":"I_kwn1","html_url":"https://github.com/o/r/issues/1",
 "title":"Ticket","body":"Body","state":"open",
 "created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-02T00:00:00Z","closed_at":null,
 "user":{"login":"operator","type":"User"},
 "labels":[{"node_id":"LA_1","name":"ai-build","description":"d","color":"ff0000"}],
 "assignees":[],"milestone":null}
J
  gshim_fixture repos_o_r_issues <<'J'
[{"number":1,"node_id":"I_kwn1","html_url":"https://github.com/o/r/issues/1",
  "title":"Ticket","body":"Body","state":"open",
  "created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-02T00:00:00Z","closed_at":null,
  "user":{"login":"operator","type":"User"},
  "labels":[{"node_id":"LA_1","name":"ai-build","description":"d","color":"ff0000"}],
  "assignees":[],"milestone":null},
 {"number":2,"node_id":"I_kwn2","html_url":"https://github.com/o/r/issues/2",
  "title":"Second ticket","body":"Body","state":"open",
  "created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-02T00:00:00Z","closed_at":null,
  "user":{"login":"operator","type":"User"},"labels":[],"assignees":[],"milestone":null}]
J
  gshim_fixture repos_o_r_issues_1_comments <<'J'
[{"node_id":"IC_1","user":{"login":"operator","type":"User"},
  "author_association":"OWNER","body":"a comment",
  "created_at":"2026-09-02T00:00:00Z","updated_at":"2026-09-02T00:00:00Z",
  "html_url":"https://github.com/o/r/issues/1#issuecomment-1"}]
J
  gshim_fixture repos_o_r_issues_2_comments <<'J'
[]
J
  gshim_fixture repos_o_r_issues_1_labels <<'J'
[{"node_id":"LA_1","name":"ai-build","description":"d","color":"ff0000"}]
J
  gshim_fixture search_issues <<'J'
{"total_count":1,"incomplete_results":false,
 "items":[{"number":1,"node_id":"I_kwn1","html_url":"https://github.com/o/r/issues/1",
   "title":"Ticket","body":"Body","state":"open","draft":false,
   "created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-02T00:00:00Z","closed_at":null,
   "user":{"login":"operator","type":"User"},
   "labels":[{"node_id":"LA_1","name":"ai-build","description":"d","color":"ff0000"}],
   "assignees":[],"milestone":null}]}
J
  gshim_fixture repos_o_r_actions_runs_42 <<'J'
{"id":42,"status":"completed","conclusion":"success","head_sha":"abc123",
 "head_branch":"main","name":"Harness CI","display_title":"a title",
 "html_url":"https://github.com/o/r/actions/runs/42",
 "created_at":"2026-09-02T00:00:00Z","updated_at":"2026-09-02T00:10:00Z",
 "event":"push","run_number":7,"run_attempt":1,"workflow_id":9}
J
  gshim_fixture repos_o_r_actions_runs <<'J'
{"total_count":1,"workflow_runs":[{"id":42,"status":"completed","conclusion":"success",
  "head_sha":"abc123","head_branch":"main","name":"Harness CI","display_title":"a title",
  "html_url":"https://github.com/o/r/actions/runs/42",
  "created_at":"2026-09-02T00:00:00Z","updated_at":"2026-09-02T00:10:00Z",
  "event":"push","run_number":7,"run_attempt":1,"workflow_id":9}]}
J
  gshim_fixture repos_o_r_actions_workflows_harness-ci.yml_runs <<'J'
{"total_count":1,"workflow_runs":[{"id":42,"status":"completed","conclusion":"failure",
  "head_sha":"abc123","head_branch":"main","name":"Harness CI","display_title":"a title",
  "html_url":"https://github.com/o/r/actions/runs/42",
  "created_at":"2026-09-02T00:00:00Z","updated_at":"2026-09-02T00:10:00Z",
  "event":"push","run_number":7,"run_attempt":1,"workflow_id":9}]}
J
  gshim_fixture repos_o_r_actions_runs_42_jobs <<J
{"total_count":2,"jobs":[{"id":$JID,"name":"build","conclusion":"failure"},
  {"id":$((JID + 1)),"name":"lint","conclusion":"success"}]}
J
  gshim_fixture "repos_o_r_actions_jobs_${JID}_logs" <<'J'
2026-09-02T00:01:00Z the build failed on line 4
J
  gshim_fixture repos_o_r_actions_runs_42_rerun-failed-jobs <<'J'
{}
J
  gshim_fixture repos_o_r_git_refs_heads_feature <<'J'
{}
J
}

# Three keys answer an ARRAY on a GET and an OBJECT on a POST whose handler
# reads .html_url off it. The write form goes in for exactly the lines that
# write, and census_fixtures_read puts the read form back for everything else.
census_fixtures_for() { # census_fixtures_for "<verb words>"
  census_fixtures_read
  case "$1" in
    "pr create")
      gshim_fixture repos_o_r_pulls <<'J'
{"number":1,"html_url":"https://github.com/o/r/pull/1"}
J
      ;;
    "issue create")
      gshim_fixture repos_o_r_issues <<'J'
{"number":1,"html_url":"https://github.com/o/r/issues/1"}
J
      ;;
    "pr comment"|"issue comment")
      gshim_fixture repos_o_r_issues_1_comments <<'J'
{"id":1,"node_id":"IC_1","html_url":"https://github.com/o/r/issues/1#issuecomment-1"}
J
      ;;
  esac
}

census_lines() { grep -vE '^[[:space:]]*(#|$)' "$1"; }

# ── the drive loop ───────────────────────────────────────────────────────────
# REPORT=1 asserts; REPORT=0 only counts, which is what the mutation block needs
# (a mutant that stays green must be a finding, not a red suite).
N_BUDGET=0; N_TRANSLATED=0; N_404=0; N_LOGGED=0; N_LINES=0
drive_census() { # drive_census <census file> <report 0|1>
  local file="$1" report="$2" raw line bang argv log calls verb
  N_BUDGET=0; N_TRANSLATED=0; N_404=0; N_LOGGED=0; N_LINES=0
  while IFS= read -r raw; do
    line="$raw"; bang=0
    case "$line" in '!'*) bang=1; line="${line#!}" ;; esac
    argv="${line//@BODYFILE@/$BODYFILE}"
    argv="${argv//@DIR@/$CLONEDIR}"
    N_LINES=$((N_LINES + 1))
    # Every quote in the census is a plain double quote around one word, and the
    # file is a repo fixture rather than caller input, so eval sees only what
    # this repo wrote.
    eval "set -- $argv"
    verb="$1 ${2:-}"
    gshim_reset
    census_fixtures_for "$verb"
    gshim_run "$@"
    log=$(logline)
    calls=$(gshim_calls)

    if [ "$bang" = 1 ]; then
      # A pass-through that says nothing is the failure mode this half exists to
      # pin: assert it logs, once, with the shim's own depth marker on the call.
      local n f2 f3
      n=$(printf '%s' "$log" | grep -c . )
      f2=$(printf '%s\n' "$log" | awk 'NR==1{print $2}')
      f3=$(printf '%s\n' "$log" | awk 'NR==1{print $3}')
      if [ "$n" = 1 ] && [ "$f2 $f3" = "$verb" ] &&
         grep -q "^depth=1 $verb" <<<"$(gshim_env)"; then
        :
      else
        N_LOGGED=$((N_LOGGED + 1))
        [ "$report" = 1 ] && bad "passthru-logged $verb: log [$log] env [$(gshim_env)]"
      fi
      [ "$report" = 1 ] && ok
      continue
    fi

    if [ -n "$log" ]; then
      N_BUDGET=$((N_BUDGET + 1))
      [ "$report" = 1 ] && bad "budget $line: $log"
    elif [ "$report" = 1 ]; then ok; fi

    if [ "$verb" = "repo clone" ]; then
      # Exempt from the api-call assertion by design: cloning is git's job and
      # the handler execs it. The git side is asserted once, below.
      :
    elif grep -q '^api ' <<<"$calls"; then
      [ "$report" = 1 ] && ok
    else
      N_TRANSLATED=$((N_TRANSLATED + 1))
      [ "$report" = 1 ] && bad "translated $line: no api call was recorded [$calls]"
    fi

    case "$ERR" in
      *"HTTP 404"*)
        N_404=$((N_404 + 1))
        [ "$report" = 1 ] && bad "no-404 $line: $ERR" ;;
      *) [ "$report" = 1 ] && ok ;;
    esac

    if [ "$verb" = "repo clone" ] && [ "$report" = 1 ]; then
      has "repo-clone-git" "$(gitcalls)" "git clone https://github.com/o/r.git"
      eq "repo-clone no REST call" "$(printf '%s' "$calls" | grep -c '^api ')" "0"
    fi
  done < <(census_lines "$file")
  return 0
}

# ── census-floor / census-parses ─────────────────────────────────────────────
NLINES=$(census_lines "$CENSUS" | grep -c .)
if [ "$NLINES" -ge 30 ]; then ok; else bad "census-floor: $NLINES lines, want >= 30"; fi

while IFS= read -r raw; do
  line="${raw#!}"
  eval "set -- $line"
  if [ "$#" -lt 2 ]; then bad "census-parses [$raw]: fewer than 2 argv words"; continue; fi
  case "$1" in
    pr|issue|run|repo) ok ;;
    *) bad "census-parses [$raw]: first word [$1] is not pr/issue/run/repo" ;;
  esac
done < <(census_lines "$CENSUS")

# ── the budget drive ─────────────────────────────────────────────────────────
drive_census "$CENSUS" 1

# ── the scanner ──────────────────────────────────────────────────────────────
# Standalone, so the SAME code scans the production tree and the adversarial
# fixtures below — a guard nobody has watched fail is a guard nobody knows is
# wired up. One `group<TAB>verb<TAB>file<TAB>line` row per call site.
cat >"$T/scan.py" <<'PY'
import os
import re
import sys

GROUPS = "pr|issue|run|repo"
CALL = re.compile(r"^gh\s+(%s)(?![A-Za-z0-9_-])\s+([A-Za-z0-9-]+)" % GROUPS)
# Prefixes that still leave the next word at command position.
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=(?:\"[^\"]*\"|'[^']*'|[^\s;|&]*)\s+")
TIMEOUT = re.compile(r"^timeout\s+(?:-k\s+\S+\s+)?\S+\s+")
ENVP = re.compile(r"^env\s+(?:-[iu]\s+\S+\s+|-[iu]\s+)*")
# Command separators, the same set tests/gh-app-ratchet-test.sh uses. Bare "("
# is NOT one: prose like "(gh pr view for PR claims)" in a heredoc is not a call.
SPLIT = re.compile(r"\$\(|<\(|\|\||&&|[|;{]"
                   r"|(?<![A-Za-z0-9_-])(?:if|elif|while|until|then|do|else)(?![A-Za-z0-9_-])|!")


def strip_comment(line):
    """Drop a `#` comment, honouring quotes so a "#" inside a string survives."""
    out, sq, dq, prev = [], False, False, ""
    for ch in line:
        if ch == "'" and not dq:
            sq = not sq
        elif ch == '"' and not sq:
            dq = not dq
        elif ch == "#" and not sq and not dq and (prev == "" or prev.isspace() or prev in ";&|("):
            break
        out.append(ch)
        prev = ch
    return "".join(out)


def scan_file(path, rows):
    with open(path, errors="ignore") as fh:
        for n, line in enumerate(fh, 1):
            code = strip_comment(line.rstrip("\n")).strip()
            if not code:
                continue
            for chunk in SPLIT.split(code):
                c = chunk.lstrip()
                while True:
                    for rx in (ASSIGN, TIMEOUT, ENVP):
                        m = rx.match(c)
                        if m:
                            c = c[m.end():].lstrip()
                            break
                    else:
                        break
                m = CALL.match(c)
                if m:
                    rows.append((m.group(1), m.group(2), path, n))


rows = []
for root in sys.argv[1:]:
    if os.path.isfile(root):
        scan_file(root, rows)
        continue
    # `bin/**/*.sh`, and every file under the other roots — the three roots the
    # ticket names. bin/gh-rest-shim and bin/lane-shims/gh do not end .sh and
    # neither calls gh at command position.
    only_sh = os.path.basename(os.path.normpath(root)) == "bin"
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d != ".git")
        for f in sorted(filenames):
            if only_sh and not f.endswith(".sh"):
                continue
            scan_file(os.path.join(dirpath, f), rows)

for g, v, p, n in rows:
    print("%s\t%s\t%s\t%s" % (g, v, p, n))
PY

scan_rows() { ( cd "$DIR" && python3 "$T/scan.py" "$@" ); }
scan_pairs() { scan_rows bin catalog skills | cut -f1,2 | tr '\t' ' ' | sort -u; }

census_pairs() { # census_pairs <file> -> "group verb", sorted, `!` stripped
  local raw line
  while IFS= read -r raw; do
    line="${raw#!}"
    eval "set -- $line"
    printf '%s %s\n' "$1" "${2:-}"
  done < <(census_lines "$1") | sort -u
}

# ── scan-nonempty ────────────────────────────────────────────────────────────
# A scanner that reaches nothing reports green forever (D12).
NPAIRS=$(scan_pairs | grep -c .)
if [ "$NPAIRS" -ge 1 ]; then ok; else bad "scan-nonempty: the scan of bin/ catalog/ skills/ found no gh call"; fi

# ── scan-negatives ───────────────────────────────────────────────────────────
# The realistic shapes a matcher gating a red build must get right. Seven that
# must NOT count, two that MUST — a negative list that quietly suppressed
# `PR=$(gh pr view …)` would make the whole ratchet decorative.
mkdir -p "$T/neg"
cat >"$T/neg/neg.sh" <<'NEG'
# gh pr merge is a GraphQL mutation
echo "run: gh issue close 1"
git commit -m "no gh pr merge here"
ghost pr view 1
bin/gh-token.sh pr view 1
gh api repos/o/r/pulls/1
gh workflow run ci.yml
cat <<'EOF'
(gh pr view for PR claims)
EOF
PR=$(gh pr view 1 --json state)
timeout 20 gh run view 42
GH_TOKEN=x gh pr list -R o/r
NEG
NEGROWS=$(scan_rows "$T/neg" | cut -f1,2 | tr '\t' ' ' | sort)
eq "scan-negatives count" "$(printf '%s' "$NEGROWS" | grep -c .)" "3"
has "scan-negatives keeps \$( " "$NEGROWS" "pr view"
has "scan-negatives keeps timeout" "$NEGROWS" "run view"
has "scan-negatives keeps NAME=value" "$NEGROWS" "pr list"
for shape in "pr merge" "issue close" "repo clone"; do
  case "$NEGROWS" in
    *"$shape"*) bad "scan-negatives: [$shape] matched a line that is not a call" ;;
    *) ok ;;
  esac
done

# ── census-covers-scan ───────────────────────────────────────────────────────
subset_misses() { # subset_misses <census file>
  comm -23 <(scan_pairs) <(census_pairs "$1")
}
MISSES=$(subset_misses "$CENSUS")
if [ -z "$MISSES" ]; then
  ok
else
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    bad "census-covers-scan: the harness calls [gh $m] and the census does not list it — add it to tests/fixtures/gh-shim-census.txt, where the shim must prove it translates it"
  done <<<"$MISSES"
fi

# ── mutation 1: pr checks un-marked ──────────────────────────────────────────
# The shim has no gshim_cmd_pr_checks, so an un-marked `pr checks` line must
# pass through, log reason=untranslated, and take the budget block red with it.
sed 's/^!pr checks/pr checks/' "$CENSUS" >"$T/census-m1.txt"
if [ "$(grep -c '^pr checks' "$T/census-m1.txt")" -ge 1 ]; then ok
else bad "mutation-1: the sed did not un-mark the pr checks line"; fi
drive_census "$T/census-m1.txt" 0
if [ "$N_BUDGET" -ge 1 ]; then ok
else bad "mutation-1 pr-checks-unmarked: the budget block stayed green — it pins nothing"; fi
has "mutation-1 reason" "$(logline)" "reason=untranslated"

# ── mutation 2: pr merge deleted ─────────────────────────────────────────────
grep -v '^pr merge ' "$CENSUS" >"$T/census-m2.txt"
if [ "$(grep -c '^pr merge ' "$T/census-m2.txt")" = "0" ]; then ok
else bad "mutation-2: the pr merge line is still in the copy"; fi
M2=$(subset_misses "$T/census-m2.txt")
case "$M2" in
  *"pr merge"*) ok ;;
  *) bad "mutation-2 pr-merge-deleted: the subset block stayed green — it pins nothing" ;;
esac

# ── mutation 3: an empty scan root ───────────────────────────────────────────
mkdir -p "$T/empty-root"
M3=$(scan_rows "$T/empty-root" | grep -c .)
eq "mutation-3 empty-scan-root rows" "$M3" "0"
# The guard scan-nonempty runs is `>= 1`. Against this root it is false, which
# is the red it would have produced — that is what makes the guard live.
if [ "$M3" -ge 1 ]; then
  bad "mutation-3 empty-scan-root: the non-empty guard would not have fired"
else
  ok
fi

# ── the drive loop is restored to the shipped census ─────────────────────────
# Re-run under the real census so a later reader of $T sees the shipped state,
# and so the mutants cannot leave a stale log behind.
drive_census "$CENSUS" 0
eq "post-mutation budget" "$N_BUDGET" "0"
eq "post-mutation 404s" "$N_404" "0"

echo "gh-passthrough-budget: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
