#!/bin/bash
# readiness-report.sh <repo-dir> [--json] [--no-run] [--print-levels]
#
# Grade a checkout 0-5 on whether this harness can build, test, review, QA and
# ship it with nobody watching — BEFORE it is enrolled, rather than discovering
# the gaps through a first failed build. Deterministic: it reads the checkout,
# optionally runs the repo's own test command under a timeout, and asks GitHub
# two read-only questions. No model is called, and nothing is written outside
# stdout and a temp dir it removes on exit.
#
#   --json          the object documented in docs/READINESS.md (this is what
#                   bin/load-project.sh --require-readiness reads)
#   --no-run        never execute the repo's test command; tests.green = skipped
#   --print-levels  print the resolved level table and exit
#
# Exit codes: 0 a report was produced — THE LEVEL IS DATA, never an exit code,
# because the caller decides what bar it wants. 2 is usage: no repo dir, an
# unreadable one, an unknown flag, an unreadable $READINESS_LEVELS, or a level
# table naming a check that does not exist.
#
# THE THIRD STATUS IS THE POINT. Every check answers pass / fail / unknown /
# skipped / na, and only `pass` earns a level. `unknown` is what a probe that
# COULD NOT RUN reports — gh unauthed, npm absent, node_modules missing — and it
# never blocks and never passes. A readiness report whose failure mode is a
# quiet yes would hand the fleet exactly the repos it cannot build.
#
# Knobs: READINESS_TEST_TIMEOUT (seconds, default 600), READINESS_GH (0 = ask
# GitHub nothing), READINESS_LEVELS (a level table, used as given).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
H="${HARNESS:-/root/harness}"
# The App-token helper (BH-425 ratchet): the two reads below go out on a
# short-lived, repo-scoped installation token instead of the fleet's one shared
# PAT wherever the box mints them. `|| true` and an unarmed box is untouched —
# gh_auth_for returns 1 without running a process and the reads stay exactly as
# they were. Sourced here, armed once $SLUG is known, reset after the last read.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$SELF_DIR/lib/gh-app-auth.sh" ] && . "$SELF_DIR/lib/gh-app-auth.sh" || true

usage() { sed -n '2,20p' "$0" >&2; }

REPO="" MODE=table NORUN=0 PRINT_LEVELS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json)         MODE=json ;;
    --no-run)       NORUN=1 ;;
    --print-levels) PRINT_LEVELS=1 ;;
    -h|--help)      sed -n '2,26p' "$0"; exit 0 ;;
    -*)             echo "readiness-report.sh: unknown flag $1" >&2; usage; exit 2 ;;
    *)              [ -z "$REPO" ] || { echo "readiness-report.sh: one repo dir, not two ($REPO, $1)" >&2; exit 2; }
                    REPO="$1" ;;
  esac
  shift
done

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

# ── the level table ─────────────────────────────────────────────────────────
# Config, not constants: which checks a level demands is a judgement that will
# be argued with, and an argument that can only be settled by editing a script
# is an argument nobody has. The builtin below is the documented fallback for a
# box that has the script and not the catalog; tests/readiness-report-test.sh A1
# pins it byte-for-byte to catalog/readiness-levels.json, because a drifted
# fallback means a repo's level depends on which box read it.
#
# --- builtin levels (fallback; catalog/readiness-levels.json is the reviewed copy) ---
BUILTIN_LEVELS='{
  "_doc": "builtin fallback copy of catalog/readiness-levels.json",
  "max_level": 5,
  "levels": {
    "1": {
      "requires": ["context.agents", "secrets.no_committed_env"],
      "must_not_fail": [],
      "unlocks": "a watcher can read the repo'"'"'s own instructions, and enrolling it leaks no committed env file"
    },
    "2": {
      "requires": ["tests.present", "secrets.env_example", "secrets.gitignore"],
      "must_not_fail": [],
      "unlocks": "a build can prove itself with a test run instead of a claim"
    },
    "3": {
      "requires": ["ci.workflow"],
      "must_not_fail": [],
      "unlocks": "a PR carries a check the merge lanes can read before they decide anything"
    },
    "4": {
      "requires": ["preview.config", "board.source"],
      "must_not_fail": ["tests.green", "ci.branch_protection", "migrations.appliable"],
      "unlocks": "eligible for tier-1 automerge (policy — no code reads this level yet, see docs/READINESS.md)"
    },
    "5": {
      "requires": ["context.vmap", "context.arch"],
      "must_not_fail": ["tests.green", "ci.branch_protection", "migrations.appliable"],
      "unlocks": "the planner'"'"'s primer and the architecture contract render from the repo itself"
    }
  }
}'

LEVELS_SOURCE=""
if [ -n "${READINESS_LEVELS:-}" ]; then
  # Used AS GIVEN and never fallen back from (same rule as $MODEL_PRICES): an
  # explicit table that silently reads a different one is how a run ends up
  # grading against rules nobody chose.
  [ -r "$READINESS_LEVELS" ] \
    || { echo "readiness-report.sh: \$READINESS_LEVELS=$READINESS_LEVELS is not readable" >&2; exit 2; }
  LEVELS_SOURCE="$READINESS_LEVELS"
else
  for C in "$H/flags/readiness-levels.json" \
           "$SELF_DIR/../catalog/readiness-levels.json" \
           "$H/catalog/readiness-levels.json"; do
    [ -r "$C" ] && { LEVELS_SOURCE="$C"; break; }
  done
fi
LEVELS="$TMPD/levels.json"
# THE DOCUMENT ROW (BH-2411, bin/lib/conf-row.sh): `conf.readiness-levels.<box>`,
# then `conf.readiness-levels`, holding the whole table as JSON, sits above
# flags/readiness-levels.json. Never read when $READINESS_LEVELS is set (that
# table is used as given). A row that is not JSON with a `.levels` object is
# named on stderr and the file chain above answers.
ROW_SOURCE=""
# shellcheck source=lib/conf-row.sh
. "$SELF_DIR/lib/conf-row.sh" 2>/dev/null || true
if [ -z "${READINESS_LEVELS:-}" ] && command -v conf_row >/dev/null 2>&1 \
   && conf_row readiness-levels "" "$H" > "$TMPD/levels-row.json"; then
  if [ "$CONF_ROW_SRC" = box-row ]; then ROW_SOURCE="settings conf.readiness-levels.$(_cr_box)"
  else ROW_SOURCE="settings conf.readiness-levels"; fi
  if jq -e '.levels | type == "object"' "$TMPD/levels-row.json" >/dev/null 2>&1; then
    conf_row_note_file readiness-levels "$H/flags/readiness-levels.json" "(document)"
    LEVELS_SOURCE="$TMPD/levels-row.json"
  else
    echo "readiness-report.sh: the ${ROW_SOURCE#settings } row is not a JSON level table with .levels — ignored, reading ${LEVELS_SOURCE:-the built-in table}" >&2
    ROW_SOURCE=""
  fi
fi
if [ -n "$LEVELS_SOURCE" ]; then
  cp "$LEVELS_SOURCE" "$LEVELS" 2>/dev/null \
    || { echo "readiness-report.sh: could not read the level table $LEVELS_SOURCE" >&2; exit 2; }
else
  printf '%s\n' "$BUILTIN_LEVELS" > "$LEVELS"
  LEVELS_SOURCE=builtin
fi
jq -e . "$LEVELS" >/dev/null 2>&1 \
  || { echo "readiness-report.sh: the level table $LEVELS_SOURCE is not valid JSON" >&2; exit 2; }
[ -n "$ROW_SOURCE" ] && LEVELS_SOURCE="$ROW_SOURCE"

if [ "$PRINT_LEVELS" = 1 ]; then
  jq --arg s "$LEVELS_SOURCE" '{levels_source:$s, max_level:.max_level, levels:.levels}' "$LEVELS"
  exit 0
fi

[ -n "$REPO" ] || { echo "readiness-report.sh: a repo dir is required" >&2; usage; exit 2; }
[ -d "$REPO" ] && [ -r "$REPO" ] \
  || { echo "readiness-report.sh: $REPO is not a readable directory" >&2; exit 2; }
# Physical path: /root/repos is a symlink on the boxes, and a logical path never
# equals `git rev-parse --show-toplevel`, so a real checkout reached through the
# symlink would read as "not a repo root" and silently skip every git question.
REPO=$(cd -P "$REPO" && pwd -P)

TMO="${READINESS_TEST_TIMEOUT:-600}"
case "$TMO" in ''|*[!0-9]*) echo "readiness-report.sh: READINESS_TEST_TIMEOUT must be whole seconds (got '$TMO')" >&2; exit 2 ;; esac

CHECKS="$TMPD/checks.tsv"; : > "$CHECKS"
# add <id> <group> <status> <detail>. One line per check, in reading order —
# the table and the JSON both render this file and never re-derive anything.
add() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$CHECKS"; }
has() { [ -e "$REPO/$1" ]; }
nonempty() { [ -s "$REPO/$1" ]; }

# Files, minus the two trees that are never the repo's own code. Used by the
# stack rows and by the committed-env scan.
repo_files() {
  find "$REPO" -name .git -prune -o -name node_modules -prune -o -type f -print 2>/dev/null
}

# ── tests ───────────────────────────────────────────────────────────────────
# What the repo's own suite is called, in the order a human would look.
RUNNER="" RUNNER_KIND="" TESTS_PRESENT=fail
PKG_TEST=""
[ -f "$REPO/package.json" ] && PKG_TEST=$(jq -r '.scripts.test // empty' "$REPO/package.json" 2>/dev/null)
if [ -n "$PKG_TEST" ] && ! grep -qi 'no test specified' <<<"$PKG_TEST"; then
  # npm's generated placeholder ("Error: no test specified && exit 1") is the
  # one test script that is worse than none: it exists, it always fails, and a
  # check that counted it would grade a repo with no suite as testable.
  TESTS_PRESENT=pass; RUNNER_KIND=npm; RUNNER="npm test"
  add tests.present tests pass "package.json scripts.test: $PKG_TEST"
elif ls "$REPO"/tests/*.sh >/dev/null 2>&1; then
  TESTS_PRESENT=pass; RUNNER_KIND=sh; RUNNER='for t in tests/*.sh; do bash "$t" || exit 1; done'
  add tests.present tests pass "tests/*.sh ($(ls "$REPO"/tests/*.sh 2>/dev/null | wc -l | tr -d ' ') suites)"
elif [ -f "$REPO/pytest.ini" ] || grep -q '\[tool.pytest' "$REPO/pyproject.toml" 2>/dev/null; then
  TESTS_PRESENT=pass; RUNNER_KIND=pytest; RUNNER="pytest -q"
  add tests.present tests pass "pytest configuration"
elif [ -f "$REPO/go.mod" ] && [ -n "$(find "$REPO" -name '*_test.go' -not -path '*/.git/*' -print -quit 2>/dev/null)" ]; then
  TESTS_PRESENT=pass; RUNNER_KIND=go; RUNNER="go test ./..."
  add tests.present tests pass "go.mod with *_test.go files"
else
  add tests.present tests fail "no test script in package.json, no tests/*.sh, no pytest config, no go tests"
fi

RAN_TESTS=false
if [ "$NORUN" = 1 ]; then
  add tests.green tests skipped "--no-run: the repo's suite was not executed"
elif [ "$TESTS_PRESENT" != pass ]; then
  add tests.green tests skipped "nothing to run — see tests.present"
else
  RBIN=${RUNNER%% *}
  DEPS=0
  [ "$RUNNER_KIND" = npm ] && jq -e '((.dependencies//{}) + (.devDependencies//{})) | length > 0' \
      "$REPO/package.json" >/dev/null 2>&1 && DEPS=1
  if [ "$RUNNER_KIND" != sh ] && ! command -v "$RBIN" >/dev/null 2>&1; then
    add tests.green tests unknown "$RBIN is not on PATH here — the suite was not run"
  elif ! command -v timeout >/dev/null 2>&1; then
    add tests.green tests unknown "timeout(1) is not on PATH — a suite is never run unbounded"
  elif [ "$DEPS" = 1 ] && [ ! -d "$REPO/node_modules" ]; then
    add tests.green tests unknown "dependencies are declared and node_modules/ is absent — run npm ci and re-run"
  else
    LOG="$TMPD/testrun.log"
    ( cd "$REPO" && timeout "$TMO" bash -c "$RUNNER" >"$LOG" 2>&1 )
    TRC=$?
    RAN_TESTS=true
    TAIL=$(tail -3 "$LOG" 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//')
    if [ "$TRC" = 0 ]; then
      add tests.green tests pass "the repo's own suite exited 0"
    elif [ "$TRC" = 124 ]; then
      # A hung suite is a FAIL, not an unknown: "we never found out" would let a
      # suite that never finishes reach the level that unlocks unattended merge.
      add tests.green tests fail "timed out after ${TMO}s"
    else
      add tests.green tests fail "the repo's own suite exited $TRC: $TAIL"
    fi
  fi
fi

# ── ci ──────────────────────────────────────────────────────────────────────
# Does the workflow actually INVOKE tests? A bare `tests/` anywhere in the file
# was a quiet yes: it matches a `paths:` trigger filter, an upload-artifact
# `path:` and a checkout path, so a lint-only workflow that merely TRIGGERS on
# `tests/**` graded "runs the tests on pull_request". Level 3's whole claim is
# that a PR carries a check the merge lanes can read, and that workflow carries
# none. Only text inside a `run:` step is a command, so only `run:` bodies are
# searched — both the one-liner (`- run: npm test`) and the ordinary block
# (`run: |` with the command on a LATER line, which is why this is not one
# anchored grep). YAML forbids tab indentation, so column counting is safe.
run_bodies() {
  awk '
    { ind = match($0, /[^ ]/) - 1 }
    in_run && (ind > runind || $0 ~ /^[ ]*$/) { print; next }
    { in_run = 0 }
    /^[ ]*-?[ ]*run:/ { in_run = 1; runind = ind; sub(/^.*run:/, ""); print }
  ' "$1"
}
CI_HIT=""
for F in "$REPO"/.github/workflows/*.yml "$REPO"/.github/workflows/*.yaml; do
  [ -f "$F" ] || continue
  grep -q 'pull_request' "$F" 2>/dev/null || continue
  run_bodies "$F" 2>/dev/null \
    | grep -qE 'npm (run )?test|pnpm (run )?test|yarn test|pytest|go test|cargo test|make test|bats |tests/' \
    || continue
  CI_HIT="${F#"$REPO"/}"; break
done
if [ -n "$CI_HIT" ]; then
  add ci.workflow ci pass "$CI_HIT runs the tests on pull_request"
else
  add ci.workflow ci fail "no .github/workflows/*.yml runs tests on pull_request — a PR carries no check"
fi

# The slug, read from the checkout's OWN remote. `git -C` walks upward, so a
# directory that merely sits inside some other checkout would otherwise be
# graded against that checkout's remote and branch protection — the answer would
# be about a repo the caller never named. Only a real repo root answers here.
TOP=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || TOP=""
IS_REPO=0; [ -n "$TOP" ] && [ "$TOP" = "$REPO" ] && IS_REPO=1
SLUG=""
REMOTE=""
[ "$IS_REPO" = 1 ] && { REMOTE=$(git -C "$REPO" remote get-url origin 2>/dev/null) || REMOTE=""; }
case "$REMOTE" in
  *github.com[:/]*) SLUG=$(printf '%s' "$REMOTE" | sed -E 's#^.*github\.com[:/]##; s#/$##; s#\.git$##') ;;
esac
case "$SLUG" in */*/*|*" "*) SLUG="" ;; esac
[ -n "$SLUG" ] || SLUG=""

# Armed BEFORE the first gh call and only when a slug was resolved; an empty
# slug, an unarmed box or a repo the App cannot see all leave GH_TOKEN alone.
[ -n "$SLUG" ] && command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true

GH_OFF=0; [ "${READINESS_GH:-1}" = 0 ] && GH_OFF=1
# PROT_READ: what the protection read answered, for ci.required_check below —
# protected | unprotected | unread.
PROT_READ=unread
if [ "$GH_OFF" = 1 ]; then
  add ci.branch_protection ci skipped "READINESS_GH=0 — GitHub was not asked"
elif ! command -v gh >/dev/null 2>&1; then
  add ci.branch_protection ci unknown "gh is not on PATH — branch protection was not read"
elif [ -z "$SLUG" ]; then
  add ci.branch_protection ci unknown "no github.com origin remote — nothing to ask about"
else
  DEF=$(gh api "repos/$SLUG" --jq .default_branch 2>"$TMPD/gh1.err")
  if [ -z "$DEF" ]; then
    # FAIL OPEN. An unauthed, rate-limited or offline gh says nothing about the
    # repo, and reading it as "not protected" would refuse repos for the state
    # of the machine running the report.
    add ci.branch_protection ci unknown "gh could not resolve the default branch of $SLUG"
  elif gh api "repos/$SLUG/branches/$DEF/protection" >"$TMPD/prot.json" 2>"$TMPD/gh2.err"; then
    add ci.branch_protection ci pass "$DEF is protected"; PROT_READ=protected
  elif grep -qi 'not protected' "$TMPD/gh2.err" 2>/dev/null; then
    # ONLY the phrase GitHub uses for the real answer ("Branch not protected").
    # A bare 404/Not Found is also what GitHub returns when the token cannot see
    # the repo at all, and reading that as "unprotected" would cost a repo a
    # level for the state of the machine running the report — the thing the
    # fail-open comment above exists to prevent.
    add ci.branch_protection ci fail "Branch not protected: $DEF"; PROT_READ=unprotected
  else
    add ci.branch_protection ci unknown "gh could not read branch protection: $(tail -1 "$TMPD/gh2.err" 2>/dev/null)"
  fi
fi

# ci.required_check (BH-6428): does anything on GitHub refuse a merge whose CI
# is red? Either a branch protection rule with required_status_checks, or a
# ruleset on the default branch with a required_status_checks rule. project-6's
# main ruleset had neither, so GitHub accepted a REST merge of a red PR.
# Report-only: no level in catalog/readiness-levels.json reads it. A read that
# failed is unknown, never fail (same reason as the fail-open comment above).
if [ "$GH_OFF" = 1 ]; then
  add ci.required_check ci skipped "READINESS_GH=0 — GitHub was not asked"
elif ! command -v gh >/dev/null 2>&1; then
  add ci.required_check ci unknown "gh is not on PATH — required status checks were not read"
elif [ -z "$SLUG" ]; then
  add ci.required_check ci unknown "no github.com origin remote — nothing to ask about"
elif [ -z "${DEF:-}" ]; then
  add ci.required_check ci unknown "gh could not resolve the default branch of $SLUG"
elif [ "$PROT_READ" = protected ] && jq -e '.required_status_checks != null' "$TMPD/prot.json" >/dev/null 2>&1; then
  add ci.required_check ci pass "the branch protection rule on $DEF requires status checks"
elif ! gh api "repos/$SLUG/rules/branches/$DEF" >"$TMPD/rules.json" 2>"$TMPD/gh3.err" \
     || ! jq -e 'type == "array"' "$TMPD/rules.json" >/dev/null 2>&1; then
  add ci.required_check ci unknown "gh could not read the rulesets on $DEF: $(tail -1 "$TMPD/gh3.err" 2>/dev/null)"
elif jq -e 'any(.[]; .type == "required_status_checks")' "$TMPD/rules.json" >/dev/null 2>&1; then
  add ci.required_check ci pass "a ruleset on $DEF requires status checks"
elif [ "$PROT_READ" = unread ] || { [ "$PROT_READ" = protected ] && ! jq -e 'type == "object"' "$TMPD/prot.json" >/dev/null 2>&1; }; then
  add ci.required_check ci unknown "no ruleset on $DEF requires a status check, and branch protection could not be read"
else
  add ci.required_check ci fail "OWED: required status check — $DEF has no ruleset or branch protection rule that requires a status check"
fi

# ── preview ─────────────────────────────────────────────────────────────────
PREV=""
for F in vercel.json .vercel/project.json wrangler.toml netlify.toml; do
  has "$F" && { PREV="$F"; break; }
done
if [ -z "$PREV" ]; then
  for F in README.md CLAUDE.md AGENTS.md; do
    [ -f "$REPO/$F" ] || continue
    # `.` and not `[^\n]`: in ERE a bracket expression has no escapes, so
    # `[^\n]` reads as "any char except backslash and the letter n" and the
    # ordinary phrasing "Preview deployments: https://…" would miss on the n in
    # "deployments". grep is line-based and ERE `.` never crosses a newline, so
    # `.` is both correct and what was meant.
    grep -qiE 'preview.*https://' "$REPO/$F" 2>/dev/null && { PREV="$F (documented preview URL)"; break; }
  done
fi
if [ -n "$PREV" ]; then
  add preview.config preview pass "$PREV"
else
  add preview.config preview fail "no vercel.json / Pages config / documented preview URL — preview QA has nothing to open"
fi

# ── board source ────────────────────────────────────────────────────────────
BOARD=""
for D in app/api/board src/app/api/board; do
  has "$D" && { BOARD="$D"; break; }
done
if [ -z "$BOARD" ]; then
  for F in "$REPO"/pages/api/board* "$REPO"/src/pages/api/board*; do
    [ -e "$F" ] && { BOARD="${F#"$REPO"/}"; break; }
  done
fi
if [ -z "$BOARD" ]; then
  for F in "$REPO"/.github/labels.yml "$REPO"/.github/labels.yaml "$REPO"/.github/labels.json \
           "$REPO"/.github/ISSUE_TEMPLATE/*; do
    [ -f "$F" ] || continue
    grep -q 'ai-build' "$F" 2>/dev/null && { BOARD="${F#"$REPO"/} names the ai-build label"; break; }
  done
fi
if [ -z "$BOARD" ] && [ "$GH_OFF" = 0 ] && [ -n "$SLUG" ] && command -v gh >/dev/null 2>&1; then
  # Only ever ADDS a pass: a gh that cannot answer leaves the offline verdict
  # alone rather than turning a real "no board source" into an unknown.
  gh label list -R "$SLUG" --json name --jq '.[].name' 2>/dev/null | grep -qx 'ai-build' \
    && BOARD="the ai-build label exists on $SLUG"
fi
# The spec-trace read (BH-6485) goes out on the same token, before the reset.
SPEC_DIRS=""
for D in design spec; do [ -d "$REPO/$D" ] && SPEC_DIRS="${SPEC_DIRS:+$SPEC_DIRS, }$D/"; done
SPEC_READ=""
if [ -n "$SPEC_DIRS" ] && [ "$GH_OFF" = 0 ] && [ -n "$SLUG" ] && command -v gh >/dev/null 2>&1; then
  if gh api "repos/$SLUG/issues?state=open&labels=ai-build&per_page=100" > "$TMPD/spec-issues.json" 2>"$TMPD/gh-spec.err" \
     && jq -e 'type == "array"' "$TMPD/spec-issues.json" >/dev/null 2>&1; then SPEC_READ=ok
  else SPEC_READ=failed; fi
fi
# Last gh read of the run — put the sourcing shell's own GH_TOKEN back.
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset || true
if [ -n "$BOARD" ]; then
  add board.source board pass "$BOARD"
else
  add board.source board fail "no /api/board route and no ai-build label metadata — the watcher has no intake"
fi

# ── spec trace (BH-6485) ────────────────────────────────────────────────────
# REPORT ONLY: no level names spec.trace, so .level never moves on it. A repo
# with a design/ or spec/ folder whose open ai-build tickets carry no `Spec:`
# line (bin/lib/spec-trace.sh's grammar) builds slices nobody checks against
# the spec. One read of the first 100 open ai-build issues; PRs are dropped.
if [ -z "$SPEC_DIRS" ]; then
  add spec.trace spec na "no design/ or spec/ folder at the repo root"
elif [ "$GH_OFF" = 1 ]; then
  add spec.trace spec skipped "READINESS_GH=0 — GitHub was not asked"
elif ! command -v gh >/dev/null 2>&1; then
  add spec.trace spec unknown "gh is not on PATH — the open ai-build issues were not read"
elif [ -z "$SLUG" ]; then
  add spec.trace spec unknown "no github.com origin remote — nothing to ask about"
elif [ "$SPEC_READ" != ok ]; then
  add spec.trace spec unknown "gh could not read the open ai-build issues of $SLUG"
elif ! [ -r "$SELF_DIR/lib/spec-trace.sh" ] || ! . "$SELF_DIR/lib/spec-trace.sh" 2>/dev/null; then
  add spec.trace spec unknown "bin/lib/spec-trace.sh is not beside this script — the issues were not graded"
else
  SPEC_ALL=0 SPEC_NO=0 SPEC_LIST=""
  while IFS=$'\t' read -r SN SB; do
    [ -n "$SN" ] || continue
    SPEC_ALL=$((SPEC_ALL + 1))
    if [ -z "$(printf '%s' "$SB" | base64 -d 2>/dev/null | st_parse spec)" ]; then
      SPEC_NO=$((SPEC_NO + 1))
      [ "$SPEC_NO" -le 10 ] && SPEC_LIST="$SPEC_LIST #$SN"
    fi
  done < <(jq -r '.[] | select(has("pull_request") | not) | "\(.number)\t\(.body // "" | @base64)"' "$TMPD/spec-issues.json" 2>/dev/null)
  SPEC_PAGE=""; [ "$(jq 'length' "$TMPD/spec-issues.json" 2>/dev/null)" = 100 ] && SPEC_PAGE=" (first 100 read)"
  if [ "$SPEC_NO" = 0 ]; then
    add spec.trace spec pass "$SPEC_DIRS present; $SPEC_ALL open ai-build issue(s), every one carries a Spec: line$SPEC_PAGE"
  else
    [ "$SPEC_NO" -gt 10 ] && SPEC_LIST="$SPEC_LIST …"
    add spec.trace spec fail "WARN: $SPEC_NO of $SPEC_ALL open ai-build issues carry no Spec: line:$SPEC_LIST ($SPEC_DIRS present)$SPEC_PAGE"
  fi
fi

# ── migrations ──────────────────────────────────────────────────────────────
MIGDIR=""
for D in prisma/migrations supabase/migrations scripts/migrations migrations db/migrate; do
  has "$D" && { MIGDIR="$D"; break; }
done
if [ -z "$MIGDIR" ]; then
  add migrations.appliable migrations na "no migrations directory — a DB-less repo is not less ready"
else
  SQL=()
  for F in "$REPO"/scripts/migrations/*.sql; do [ -f "$F" ] && SQL+=("$F"); done
  LINT="$SELF_DIR/check-migration-appliable.sh"
  if [ "${#SQL[@]}" -eq 0 ]; then
    # UNKNOWN, not pass. `scripts/migrations/*.sql` is the only shape
    # check-migration-appliable.sh reads, so a prisma/ or supabase/ migrations
    # directory — `DROP TABLE` and all — was never graded. Passing it satisfied
    # level 4's `must_not_fail` BY SILENCE at the level the docs call tier-1
    # eligible; unknown is the third status this report exists to have.
    add migrations.appliable migrations unknown "$MIGDIR exists but holds no scripts/migrations/*.sql — the only shape the linter reads — so its SQL was NOT graded"
  elif [ ! -x "$LINT" ]; then
    add migrations.appliable migrations unknown "check-migration-appliable.sh is not beside this script — the SQL was not linted"
  else
    "$LINT" "$(basename "$REPO")" "$REPO" "${SQL[@]}" > "$TMPD/mig.txt" 2>&1
    MRC=$?
    if [ "$MRC" = 0 ]; then
      add migrations.appliable migrations pass "${#SQL[@]} file(s) in scripts/migrations pass the apply classifier"
    elif [ "$MRC" = 1 ]; then
      add migrations.appliable migrations fail "$(grep -c 'FLAGGED' "$TMPD/mig.txt" 2>/dev/null || echo '?') statement(s) the apply endpoint would refuse"
    else
      add migrations.appliable migrations unknown "the migration linter exited $MRC — the SQL was not graded"
    fi
  fi
fi

# ── agent context ───────────────────────────────────────────────────────────
if nonempty AGENTS.md; then add context.agents context pass "AGENTS.md"
elif nonempty CLAUDE.md; then add context.agents context pass "CLAUDE.md"
else add context.agents context fail "no AGENTS.md or CLAUDE.md — a build has nothing repo-specific to read"; fi

nonempty AGENT_ARCHITECTURE.md \
  && add context.arch context pass "AGENT_ARCHITECTURE.md" \
  || add context.arch context fail "no AGENT_ARCHITECTURE.md — no architecture contract to plan against"

# The index may be a committed file (a target repo) or a GENERATED one that is
# never committed (cromford since BH-1175, and any repo that copies that
# layout). Either shape is a map a planner can read, so both pass — grading a
# repo DOWN for generating its index would have made the fix to the harness's
# own merge-conflict tail read as a readiness regression.
if nonempty docs/verification-map/README.md; then
  add context.vmap context pass "docs/verification-map/README.md"
elif nonempty docs/verification-map/index/head.md \
     && [ -n "$(find "$REPO/docs/verification-map/entries" -maxdepth 1 -type f -name '*.md' 2>/dev/null | head -1)" ]; then
  add context.vmap context pass "docs/verification-map/ (index generated by bin/verification-map-build.sh, entries committed)"
else
  add context.vmap context fail "no docs/verification-map/ — QA has to rediscover the screens every build"
fi

# Info only: no level requires either, so neither can ever appear as a gap.
has .codegraph \
  && add context.codegraph context pass ".codegraph/ index present (info only)" \
  || add context.codegraph context fail "no .codegraph/ index (info only — indexing is the repo owner's call)"
if has .factory; then add context.conventions context pass ".factory/ (info only)"
elif has .agents; then add context.conventions context pass ".agents/ (info only)"
else add context.conventions context fail "no .factory/ or .agents/ conventions (info only)"; fi

# ── secrets shape ───────────────────────────────────────────────────────────
EXF=""
for F in .env.example .env.sample .env.template; do has "$F" && { EXF="$F"; break; }; done
[ -n "$EXF" ] \
  && add secrets.env_example secrets pass "$EXF" \
  || add secrets.env_example secrets fail "no .env.example — nothing states which env this repo needs"

# Tracked files where the checkout has git, every file otherwise: a fixture (and
# a fresh export) is a plain directory, and a scan that only understood git
# would report a clean tree for a repo that is not one.
# ANY `.env.<something>`, not a list of three siblings. `.env.vercel` is the
# exact file that leaked seven live keys on project-3, and `.env.staging`,
# `.env.test` and `.env.prod` are no different — a check that named only
# local/production/development answered "no committed .env" about a tree that
# has one. The declaring siblings (.env.example / .sample / .template) are the
# files secrets.env_example REQUIRES, so they are excluded by name.
ENV_ANY='(^|/)\.env(\.[A-Za-z0-9_.-]+)?$'
ENV_DECL='\.env\.(example|sample|template)$'
if [ "$IS_REPO" = 1 ]; then
  COMMITTED=$(git -C "$REPO" ls-files 2>/dev/null \
    | grep -E "$ENV_ANY" | grep -vE "$ENV_DECL" || true)
else
  COMMITTED=$(repo_files \
    | sed "s#^$REPO/##" \
    | grep -E "$ENV_ANY" | grep -vE "$ENV_DECL" || true)
fi
if [ -n "$COMMITTED" ]; then
  # Paths only, never contents: this report is read in PR bodies and logs.
  add secrets.no_committed_env secrets fail "committed env file(s): $(printf '%s' "$COMMITTED" | tr '\n' ' ' | sed 's/ $//')"
else
  add secrets.no_committed_env secrets pass "no committed .env in the tree"
fi

# The root-anchored `/.env` and the any-depth `**/.env` are as common as the
# bare form and cover exactly the same file, so they read as coverage too. What
# still must NOT count: `.env.local` (covers one sibling, not `.env`), `.envrc`,
# and a `!`-prefixed un-ignore line — this is a level-2 requirement, and a false
# pass here is the check saying the next env file is safe when it is not.
#
# `.env.*` is that same shape and used to pass here. In git the `.` after `env`
# is LITERAL: `.env.*` ignores `.env.local` and never the bare `.env`
# (`git check-ignore -v .env` lists nothing under it). `.env*` does cover it —
# `*` matches zero characters — so only the `\.\*` alternative is dropped.
if [ -f "$REPO/.gitignore" ] && grep -qE '^/?(\*\*/)?\.env\*?$|^\*\.env$' "$REPO/.gitignore" 2>/dev/null; then
  add secrets.gitignore secrets pass ".gitignore covers .env"
else
  add secrets.gitignore secrets fail ".gitignore does not cover .env — the next env file lands in a commit"
fi

# ── size / stack (info only; the adapters line is what QA and deploy read) ───
NFILES=$(repo_files | wc -l | tr -d ' ')
# Not `LANG`: that name is the locale, and exporting it to the renderer below
# would set python3's locale to "ts".
# `sed -E`, not BRE: `\|` alternation is a GNU extension, so on a Mac the BRE
# form matched nothing and every repo reported language=unknown. load-project.sh
# is documented "run from ANY cromford checkout (Mac or hub)".
PRIMARY_LANG=$(repo_files | sed -nE 's/.*\.(ts|tsx|js|py|go|rb|sh)$/\1/p' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
[ -n "$PRIMARY_LANG" ] || PRIMARY_LANG=unknown
FRAMEWORK=unknown
if ls "$REPO"/next.config.* >/dev/null 2>&1; then FRAMEWORK=next
elif has manage.py; then FRAMEWORK=django
elif [ -f "$REPO/Gemfile" ] && grep -qi 'rails' "$REPO/Gemfile" 2>/dev/null; then FRAMEWORK=rails
elif has go.mod; then FRAMEWORK=go
elif has wrangler.toml; then FRAMEWORK=cloudflare
fi
ADAPTERS=not-yet
[ "$FRAMEWORK" = next ] && ADAPTERS=supported

# ── level math + rendering ──────────────────────────────────────────────────
REPO="$REPO" LEVELS="$LEVELS" LEVELS_SOURCE="$LEVELS_SOURCE" CHECKS="$CHECKS" \
MODE="$MODE" RAN_TESTS="$RAN_TESTS" SLUG="$SLUG" \
NFILES="$NFILES" PRIMARY_LANG="$PRIMARY_LANG" FRAMEWORK="$FRAMEWORK" ADAPTERS="$ADAPTERS" \
python3 - <<'PY'
import json, os, sys

checks = []
with open(os.environ["CHECKS"]) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        cid, group, status, detail = (line.split("\t", 3) + ["", "", ""])[:4]
        checks.append({"id": cid, "group": group, "status": status, "detail": detail})
by_id = {c["id"]: c for c in checks}

table = json.load(open(os.environ["LEVELS"]))
levels = table.get("levels", {})
max_level = int(table.get("max_level", max([int(k) for k in levels] or [0])))

# A typo in the level table must never silently relax a gate: a level that
# requires a check nobody computes would be trivially satisfied.
unknown = sorted({c for spec in levels.values()
                  for key in ("requires", "must_not_fail")
                  for c in spec.get(key, [])} - set(by_id))
if unknown:
    sys.stderr.write("readiness-report.sh: the level table names unknown check(s): %s\n" % ", ".join(unknown))
    sys.exit(2)

def blocked(n):
    """Every reason level n is not reached, given every level at or below it."""
    out = []
    for lv in range(1, n + 1):
        spec = levels.get(str(lv), {})
        for cid in spec.get("requires", []):
            c = by_id[cid]
            if c["status"] != "pass":
                out.append({"level": n, "check": cid, "status": c["status"], "detail": c["detail"]})
        for cid in spec.get("must_not_fail", []):
            c = by_id[cid]
            if c["status"] == "fail":
                out.append({"level": n, "check": cid, "status": c["status"], "detail": c["detail"]})
    return out

level = 0
for n in range(1, max_level + 1):
    if blocked(n):
        break
    level = n

# Gaps: what each level ABOVE the achieved one is still waiting on, cheapest
# first, deduplicated so a check missing at level 2 is not re-listed at 3, 4, 5.
gaps, seen = [], set()
for n in range(level + 1, max_level + 1):
    for g in blocked(n):
        if g["check"] in seen:
            continue
        seen.add(g["check"])
        gaps.append(g)

stack = {"files": int(os.environ["NFILES"]), "language": os.environ["PRIMARY_LANG"],
         "framework": os.environ["FRAMEWORK"], "adapters": os.environ["ADAPTERS"]}
repo = os.environ["REPO"]
ran = os.environ["RAN_TESTS"] == "true"
src = os.environ["LEVELS_SOURCE"]

if os.environ["MODE"] == "json":
    # `slug` is the origin remote of the checkout that was GRADED (empty when the
    # directory is not a repo root or has no github.com origin). A caller that
    # names a repo of its own — load-project.sh does — compares the two, so a
    # level computed from somebody else's checkout cannot be read as this repo's.
    print(json.dumps({"schema": 1, "repo": repo, "slug": os.environ.get("SLUG", ""),
                      "level": level, "max_level": max_level,
                      "levels_source": src, "ran_tests": ran,
                      "checks": checks, "gaps": gaps, "stack": stack}, indent=2))
    sys.exit(0)

print("readiness: %s" % repo)
print("levels:    %s" % src)
print()
print("%-26s %-8s %s" % ("check", "status", "detail"))
for c in checks:
    print("%-26s %-8s %s" % (c["id"], c["status"], c["detail"]))
print("%-26s %-8s %s" % ("stack", "info",
      "files=%d language=%s framework=%s adapters=%s"
      % (stack["files"], stack["language"], stack["framework"], stack["adapters"])))
print()
if gaps:
    print("gaps (what the next levels are waiting on):")
    for g in gaps:
        print("  level %d  %-24s %-8s %s" % (g["level"], g["check"], g["status"], g["detail"]))
else:
    print("gaps: none")
unlocks = levels.get(str(level), {}).get("unlocks", "")
if unlocks:
    print()
    print("at this level: %s" % unlocks)
print()
# LAST LINE, always: bin/load-project.sh decides from --json (one run, so its
# terminal output and its verdict cannot disagree), and every other reader greps
# this one line.
print("READINESS LEVEL: %d/%d" % (level, max_level))
PY
exit $?
