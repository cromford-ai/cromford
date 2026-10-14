#!/bin/bash
# bin/test-impact.sh — WHICH SUITES CAN THIS DIFF REACH? (BH-1203)
#
# CI ran the whole corpus on every PR. After BH-1192 that is four shards and
# ~13 minutes, but it is still every suite in the tree to prove that a docs/
# paragraph did not break the merge conductor. This script answers the narrower question the
# shards should be asking: given a diff, which suites could possibly see it?
#
#   bin/test-impact.sh map                 build the map (default: print it)
#   bin/test-impact.sh select <a>..<b>     the suites that diff can reach
#   bin/test-impact.sh ci-select           the same, deciding full-vs-selected
#                                          from the CI environment
#   bin/test-impact.sh orphans             scripts NO suite reaches
#   bin/test-impact.sh orphans --check     the orphans this diff ADDS, against
#                                          the merge-base; refuses a tracked list
#   bin/test-impact.sh audit               rows the map is MISSING (must be empty)
#   bin/test-impact.sh always              the suites every diff runs
#   bin/test-impact.sh always-why          the same, `<suite>\t<why>`: the line
#                                          that put it there, or the catalog
#   bin/test-impact.sh inputs              every input of every suite, for the
#                                          suite fingerprint (BH-5366; v2 BH-6406)
#
# Flags: --root <dir> (default: this checkout), --out <file> (default: stdout),
#        --map <file> (use this map instead of building one — tests only),
#        --check (orphans only: no orphan may be NEW against TI_BASE / the
#        merge-base with origin/main).
#   select only (BH-1524):
#        --why           print `<suite>\t<kind>\t<path>` rows instead of bare
#                        suites — WHY each one was picked (see "THE WHY COLUMN")
#        --changed <f>   the changed paths as a list, one per line, instead of
#                        a <base>..<head> range (replays and fixtures)
#        --map-only      the map's own picks even when CI would run the corpus
#                        (infra / unknown reach) — the builder gate's question;
#                        the reason line still names what CI will do
#   env TI_BATCH_SELECT=1 (BH-6059; only bin/ci-plan.sh's merge-queue batch
#                        select sets it): catalog/ is not infra, the batch's
#                        rules file names the catalogs that are. A bin/lib/ or
#                        catalog/ path with no SPECIFIC map row (one other than
#                        the whole-tree rows bin/, bin/lib/, catalog/) is
#                        `full: unmapped path (<p>)`. A *.md there never goes
#                        full, and selects only through its specific rows.
#                        tests/lib/ is not infra here either (BH-6371): a
#                        changed helper selects through its helper closure
#                        (ti_testlib_closure), and a closure with no map row
#                        that names one of its files is
#                        `full: unmapped path (<p>)`. The global helpers
#                        (tests/lib/scratch.sh) escalate in the batch's rules
#                        file before this runs.
#   env TI_WORKFLOW_BASE=<sha> (BH-6688; batch select only): a changed
#                        .github/workflows/harness-ci.yml whose diff from <sha>
#                        to HEAD bin/test-impact-workflow.sh calls non-test
#                        jobs only (rc 1) selects through its map rows instead
#                        of `full: infra change`. Unset, or any other answer,
#                        is the infra answer.
#
# ── THE MAP IS GENERATED AND NEVER COMMITTED (BH-1175's rule, applied) ───────
# BH-1175 took docs/verification-map/README.md out of git because a file derived
# from committed sources, that moves on nearly every PR, conflicts on every
# rebase of a drain: it was in 105 of the last 200 merges and turned main red
# three times in one day. catalog/test-impact.tsv is the same shape — it moves
# whenever any suite, any bin/ script or any `source` line moves, which is most
# PRs — so it is gitignored and every consumer builds it. A build is ~3 seconds.
#
# BH-1268 applied the same rule to the two files left: the ORPHAN LIST is
# derived here and git-ignored (the ratchet below compares two trees instead of
# a tree and a committed file), and docs/LLM_CALL_SITES.md is rendered by
# bin/llm-sites-build.sh. Nothing this script produces is in git.
#
# That removes a trigger the ticket asked for: "the map is stale" cannot happen,
# because there is no stored map to go stale. What replaces it is the opposite
# failure — a map that could not be BUILT — and that falls through to the whole
# corpus with a reason, never to a small green run.
#
# ── WHAT THE MAP IS ─────────────────────────────────────────────────────────
# Rows are `<suite>\t<path>`, sorted, where <path> is one of:
#
#   bin/lib/x.sh    a file: this suite runs when that file changes
#   bin/lib/mc/     a directory: this suite runs when anything under it changes
#   *               the whole tree: this suite runs on EVERY diff
#
# Rows also come from catalog/test-impact-learned.d/*.tsv, the LEARNED edges:
# bin/impact-learn.sh writes one when a merge-queue batch failed a suite that
# the map did not select for the culprit's paths (ti_learned_rows). `select
# --why` prints a learned path pick that the suite text does not name as
# `learned` (BH-6459); a learned `*` row stays `always`.
#
# A suite's paths are the literal repo paths its TEXT names, closed over what
# those scripts `source`. That is a static over-approximation on purpose: it can
# name a file the suite never actually opens (harmless — one extra suite runs),
# and the whole design of the selection around it is that everything it cannot
# see falls back to the full corpus rather than to a silent skip.
#
# ── WHY THE EXTRACTION IS ROOTED ────────────────────────────────────────────
# A naive `grep -o 'bin/[^ ]*'` over tests/ is useless here: 284 of the 441
# suites mention `bin/` and almost all of those are the suite writing into its
# OWN scratch harness — `chmod +x "$H/bin/"*.sh`, `cp "$DIR/bin/$f" "$T/bin/$f"`.
# Counting `$T/bin/` as a dependency on the repo's bin/ would put two thirds of
# the corpus in every diff and the lane would save nothing.
#
# So a path token counts only when it is REPO-ROOTED: at the start of a word, or
# behind $DIR / $ROOT / $REPO / $HERE / $D — the four names this repo's suites
# give the checkout (500 of them use DIR). A token behind any other variable is
# a scratch path and is dropped. A bare token must resolve to a real FILE; only
# a rooted one may name a directory, because `the bin/ lane` in a comment is
# prose and `"$DIR/bin/lib/mc/$m.sh"` is a dependency on every mc module.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# The resolved path to THIS script. `orphans --check` re-runs it against the
# base tree, and $0 alone would not survive the cd into a temp directory.
TI_SELF="$SELF_DIR/$(basename "$0")"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
OUT=""
MAP_OVERRIDE=""
CHECK=0
WHY=0
CHANGED_FILE=""
MAP_ONLY=0
CMD=""
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "test-impact: --root needs a directory" >&2; exit 2; }
            ROOT="$2"; shift ;;
    --root=*) ROOT="${1#--root=}" ;;
    --out)  [ $# -ge 2 ] || { echo "test-impact: --out needs a path" >&2; exit 2; }
            OUT="$2"; shift ;;
    --out=*) OUT="${1#--out=}" ;;
    --map)  [ $# -ge 2 ] || { echo "test-impact: --map needs a path" >&2; exit 2; }
            MAP_OVERRIDE="$2"; shift ;;
    --map=*) MAP_OVERRIDE="${1#--map=}" ;;
    --check) CHECK=1 ;;
    --why)   WHY=1 ;;
    --map-only) MAP_ONLY=1 ;;
    --changed) [ $# -ge 2 ] || { echo "test-impact: --changed needs a path" >&2; exit 2; }
            CHANGED_FILE="$2"; shift ;;
    --changed=*) CHANGED_FILE="${1#--changed=}" ;;
    -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
    -*)     echo "test-impact: unknown flag $1" >&2; exit 2 ;;
    *)      if [ -z "$CMD" ]; then CMD="$1"; else ARGS+=("$1"); fi ;;
  esac
  shift
done

# --check answers one question and only `orphans` asks it. Accepting it silently
# elsewhere would let `select --check` read as a check that passed.
if [ "$CHECK" = 1 ] && [ "$CMD" != orphans ]; then
  echo "test-impact: --check is only for 'orphans' (got '${CMD:-<none>}')" >&2; exit 2
fi
# The same for the three select-only flags: `map --why` printing an ordinary
# map would read as a map that had been explained.
if { [ "$WHY" = 1 ] || [ -n "$CHANGED_FILE" ] || [ "$MAP_ONLY" = 1 ]; } && [ "$CMD" != select ]; then
  echo "test-impact: --why, --changed and --map-only are only for 'select' (got '${CMD:-<none>}')" >&2; exit 2
fi
[ -d "$ROOT" ] || { echo "test-impact: no such root: $ROOT" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd)"

# The top-level directories a suite can exercise. Anything OUTSIDE this list is
# either documentation (inert, see ti_inert) or unknown reach, and unknown reach
# means the whole corpus — so adding a new source directory to the repo without
# adding it here costs a full CI run, never a missed suite.
TI_PREFIX='bin|worker|console-ui|mcp|agent-core|locks-worker|cron|catalog|env-templates|guardrails|checks|prompts|fly|config|rules|skills|orchestrator|tasks|tests|docs|\.github|\.harness|fleet\.conf|vercel\.conf|\.gitattributes|\.gitignore|\.mergify\.yml'
# The names this repo's suites give the checkout root. See the header.
TI_ROOTVAR='DIR|ROOT|REPO|HERE|D'
# The same list with the dots written as a class instead of a backslash escape.
# It is handed to awk through -v, and -v processes escape sequences in its value,
# so a `\.` arriving there is at best a warning and at worst a literal
# backslash. `[.]` means the same thing and survives the trip.
#
# NO REDUNDANT ALTERNATIVE MAY APPEAR HERE. It carried `fleet[.]conf` and
# `vercel[.]conf` beside the generic `[A-Za-z0-9_-]+[.](md|conf)`, which already
# matches both — harmless under gawk (leftmost-LONGEST) and not under mawk,
# whose match() took the shorter, later alternative and returned the UNROOTED
# `fleet.conf` at RSTART 27 instead of `@ROOT@/fleet.conf` at 20. The extractor
# then dropped it as a scratch path, so 36 suites silently lost their
# fleet.conf row on every fleet box while the map still looked healthy.
TI_PREFIX_AWK='bin|worker|console-ui|mcp|agent-core|locks-worker|cron|catalog|env-templates|guardrails|checks|prompts|fly|config|rules|skills|orchestrator|tasks|tests|docs|[A-Za-z0-9_-]+[.](md|conf)|[.]github|[.]harness|[.]gitattributes|[.]gitignore|[.]mergify[.]yml'

# ── HOW A SUITE NAMES THE CHECKOUT ──────────────────────────────────────────
# Five spellings, all of them in this corpus, and the first version of this
# script recognised only the first. That is BH-1203 review finding B1: eight
# suites that exist to test one script each got no row for it, and because OTHER
# suites mapped those files the path read as covered, so the unknown-reach net
# never opened and the suite was simply dropped.
#
#   $DIR/bin/x            a variable assigned from the idiom (500 suites)
#   $(cd "$(dirname "$0")/.." && pwd)/bin/x       the idiom, inline
#   $(dirname "$0")/../bin/x                      the short inline form
#   $H/bin/x              a variable OTHER than DIR assigned from the idiom
#   {DIR}/bin/x           the same variable inside a python f-string
#
# Every line is NORMALISED before anything is extracted: each of these becomes
# the literal marker `@ROOT@/`, and the extractor then has one form to know
# about instead of five. Adding a sixth spelling is one gsub here, not a new
# branch everywhere.
#
# THE FOURTH ONE HAS TO BE PER SUITE. `$H` is the checkout in
# tests/codex-model-capture-test.sh and a scratch harness in 958 other places;
# a global H would map most of the corpus onto bin/ and the lane would save
# nothing. So a variable earns root status only in the suite whose own text
# assigns it from the idiom, and `ti_rootvars` works that out one suite at a
# time.
TI_AWK_NORM='
# ti_join — fold os.path.join(@ROOT@, "a", "b") into @ROOT@/a/b, any depth.
# String literals only: the first non-literal argument ends the fold and what is
# left is the directory above it, which is the safe direction. Double quotes
# only, because every join in this corpus uses them.
function ti_join(line,   p, head, rest, out, m) {
  while ((p = index(line, "os.path.join(@ROOT@")) > 0) {
    head = substr(line, 1, p - 1)
    rest = substr(line, p + 19)
    out = "@ROOT@"
    while (match(rest, /^[ \t]*,[ \t]*"[^"]*"/)) {
      m = substr(rest, RSTART, RLENGTH)
      sub(/^[ \t]*,[ \t]*"/, "", m); sub(/"$/, "", m)
      out = out "/" m
      rest = substr(rest, RSTART + RLENGTH)
    }
    if (match(rest, /^[ \t]*\)/)) rest = substr(rest, RSTART + RLENGTH)
    line = head out rest
  }
  return line
}
function ti_norm(line, suite,   rv) {
  gsub(/\$\(cd "?\$\(dirname "?\$0"?\)\/\.\."? *&& *pwd\)/, "@ROOT@", line)
  gsub(/\$\(cd "?\$\(dirname "?\$0"?\)"? *&& *pwd\)/, "@TESTS@", line)
  gsub(/\$\(dirname "?\$0"?\)\/\.\.\//, "@ROOT@/", line)
  gsub(/\$\(dirname "?\$0"?\)\//, "@TESTS@/", line)
  # The SIXTH spelling (BH-1203 review B2): the suite hands the checkout to
  # python on the command line — `python3 - "$DIR" <<PY` — and inside the
  # heredoc it is sys.argv[1]. The flag is per suite, set by ti_rootvars from
  # that invocation, so `sys.argv[1]` means the checkout only where one was
  # actually passed.
  if (suite in PY_) gsub(/sys\.argv\[1\]/, "@ROOT@", line)
  rv = RV_[suite]
  if (rv == "") rv = ROOTVAR_
  else rv = rv "|" ROOTVAR_
  gsub("(\\$\\{?(" rv ")\\}?|\\{(" rv ")\\})\"?/", "@ROOT@/", line)
  gsub(/@ROOT@"\//, "@ROOT@/", line)
  gsub(/@TESTS@\//, "@ROOT@/tests/", line)
  # Python builds its paths piecewise, so the path only exists after the join is
  # folded: os.path.join(root, "bin", "share") IS bin/share. The root variable
  # is BARE inside the call — no trailing slash — so the rule above cannot see
  # it and this line hands the join its marker first.
  gsub("os\\.path\\.join\\((" rv ")[ \t]*,", "os.path.join(@ROOT@,", line)
  line = ti_join(line)
  return line
}
'

# ti_rootvars <suite>... — "<suite>\t<NAME>" for every variable a suite assigns
# FROM the checkout idiom. The assignment is recognised after the idiom is
# normalised, so one rule covers `DIR=$(cd …)`, `H="$(cd …)"` and
# `export R=$(cd …)`. The right hand side must be the root and NOTHING else:
# `V="$(cd …)/bin/x.sh"` names a FILE, that line already yields the file, and
# treating V as a directory root afterwards would be wrong.
#
# THE SUITES ARRIVE AS ARGUMENTS, NEVER AS AN UNQUOTED $(ls …). An empty glob
# left awk with no file operand, and awk with no file operand reads STDIN — so
# a tree with no suites did not fail, it BLOCKED, for as long as whatever
# launched it kept a terminal or a pipe open. Called with none, this is rc 2.
ti_rootvars() {
  [ $# -gt 0 ] || { echo "test-impact: ti_rootvars was given no suites" >&2; return 2; }
  ( cd "$ROOT" && LC_ALL=C awk -v ROOTVAR_="$TI_ROOTVAR" '
      FILENAME != cur { cur = FILENAME; py = 0 }
      {
        line = $0
        gsub(/\$\(cd "?\$\(dirname "?\$0"?\)\/\.\."? *&& *pwd\)/, "@ROOT@", line)
        gsub("\\$\\{?(" ROOTVAR_ ")\\}?", "@ROOT@", line)
        # The checkout handed to python on the command line: everything after it
        # in THIS suite may call the checkout sys.argv[1] (review B2).
        if (!py && line ~ /python3?[ \t]+-/ && index(line, "@ROOT@") > 0) {
          py = 1; print FILENAME "\t@PYARGV@"
        }
        if (py) gsub(/sys\.argv\[1\]/, "@ROOT@", line)
        # Shell (NAME=…) and python (NAME = …) assignments whose right hand side
        # is the root and nothing else. `V="@ROOT@/bin/x.sh"` names a FILE: that
        # line already yields the file, and V is not a directory root.
        if (match(line, /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=["'"'"']?@ROOT@["'"'"']?[ \t]*(;|$)/) ||
            match(line, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]+=[ \t]+@ROOT@[ \t]*(#.*)?$/)) {
          nm = substr(line, RSTART, RLENGTH)
          sub(/^[ \t]*(export[ \t]+)?/, "", nm)
          sub(/[ \t]*=.*$/, "", nm)
          if (nm != "") print FILENAME "\t" nm
        }
      }
    ' "$@" ) | LC_ALL=C sort -u
}

TI_TMP=""
ti_cleanup() { [ -n "$TI_TMP" ] && rm -rf "$TI_TMP"; }
trap ti_cleanup EXIT
TI_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-impact.XXXXXX") || {
  echo "test-impact: cannot make a temp dir" >&2; exit 2; }

# ── the tree index ──────────────────────────────────────────────────────────
# Every tracked file, one per line, repo-relative. git is preferred because it
# already excludes logs/, state/ and builds/ — on a box those hold hundreds of
# thousands of files and a find would be the slowest thing in CI. A tree that is
# not a git checkout (the suites build several) falls back to find with the same
# directories pruned.
# THE UNIVERSE IS WHAT GIT TRACKS: a diff is made of tracked paths, so the
# universe has to be tracked paths. Since BH-5518 C2 no tracked file sits under
# an ignore rule, and tests/generated-not-tracked.bh-5518-test.sh G1 holds that.
# THE THREE GENERATED-PATH ALIASES (BH-6005, BH-4987, BH-6487):
# worker/<w>/schema.sql is composed from worker/<w>/schema.d/,
# catalog/llm-sites.json from catalog/llm-sites.d/ and
# catalog/context-budgets.json from catalog/context-budgets.d/; suites name the
# composed file. When a tracked source directory has no tracked composed file,
# the universe still carries the path, so a suite that names
# "$DIR/worker/<w>/schema.sql", "$DIR/catalog/llm-sites.json" or
# "$DIR/catalog/context-budgets.json" keeps its row.
ti_files() {
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" ls-files | awk '
      { print; seen[$0] = 1 }
      /^worker\/[^\/]+\/schema\.d\// { split($0, p, "/"); w[p[2]] = 1 }
      /^catalog\/llm-sites\.d\// { sites = 1 }
      /^catalog\/context-budgets\.d\// { budgets = 1 }
      END {
        for (k in w) if (!(("worker/" k "/schema.sql") in seen)) print "worker/" k "/schema.sql"
        if (sites && !("catalog/llm-sites.json" in seen)) print "catalog/llm-sites.json"
        if (budgets && !("catalog/context-budgets.json" in seen)) print "catalog/context-budgets.json"
      }'
  else
    ( cd "$ROOT" && find . \
        \( -name .git -o -name node_modules -o -name logs -o -name state \
           -o -name builds -o -name locks -o -name flags \) -prune -o \
        -type f -print ) | sed 's|^\./||'
  fi | LC_ALL=C sort
}

# ── the suites ──────────────────────────────────────────────────────────────
# tests/*.sh and tests/mc/*.sh, exactly the corpus bin/test-suite-run.sh sweeps.
# tests/lib/ is deliberately not here: those are libraries the suites source,
# not suites. A change to one of them forces the whole corpus, except in a
# batch select, where it selects through ti_testlib_closure (BH-6371).
ti_suites() {
  ( cd "$ROOT" && ls tests/*.sh tests/mc/*.sh 2>/dev/null ) | LC_ALL=C sort
}

# ── awk helpers shared by both passes ───────────────────────────────────────
# Reads the index on its first input file and answers "is this a file / a
# directory" without forking a `test` per token. Thirteen thousand tokens come
# out of the suite scan; thirteen thousand forks would be the slow part.
TI_AWK_INDEX='
function lastslash(s,   i) { for (i = length(s); i > 0; i--) if (substr(s, i, 1) == "/") return i; return 0 }
function adddirs(p,   q, n) { q = p; while ((n = lastslash(q)) > 0) { DIR_[substr(q, 1, n)] = 1; q = substr(q, 1, n - 1) } }
function isfile(p) { return (p in FILE_) }
function isdir(p)  { if (p in DIR_) return 1; return ((p "/") in DIR_) }
function asdir(p)  { if (p in DIR_) return p; if (((p "/")) in DIR_) return p "/"; return "" }
'

# ti_source_edges — "<script>\t<sourced file>" for every `source`/`.` line in
# every shell script in the tree, resolved against the index.
#
# Three spellings all reach the same file and all three are in this repo:
#   . "$H/bin/lib/x.sh"                     absolute from the harness root
#   . "$(dirname "$0")/lib/x.sh"            relative to the script
#   # shellcheck source=lib/x.sh            the directive, when the line above
#                                           is too dynamic for shellcheck
# and one that resolves to a DIRECTORY on purpose:
#   . "$HARNESS/bin/lib/rb/$_m.sh"          every module in the split
# The variable segment is unreadable statically, so the token stops at the last
# literal slash and the whole directory becomes the dependency. Over-approximate
# in the safe direction: the alternative is a stage module whose change selects
# nothing.
#
# HOW THE VARIABLE SEGMENTS ARE HANDLED, because the first version of this
# comment promised the first and fourth spellings and did not deliver them
# (BH-1253). `$` is one of the token SEPARATORS below, so `$HARNESS/bin/lib/x.sh`
# tokenised to `HARNESS/bin/lib/x.sh` — not a path in this tree, so it resolved
# to nothing, and thirty unbraced source lines in bin/ produced no edge at all.
# The braced `${HARNESS}/…` worked only by accident, `}` being a separator too.
# So every `$NAME` and `${NAME}` is BLANKED before the split and the token
# begins at the `/`, which the leading-slash strip below already handles. The
# blanking is deliberately narrow: `$` must be followed by a letter or an
# underscore, so `$0`, `$1` and `$(cd …)` are untouched, and `${NAME:-/def}`
# loses only its `${NAME` prefix — the remainder resolves to nothing and is
# dropped exactly as it is today.
#
# This pass is NOT root-aware, and that is deliberate: inside bin/ there is no
# scratch-versus-repo distinction to make. $HARNESS/bin IS bin.
#
# KNOWN BLIND SPOT (BH-1203 review N2): the closure follows `source`/`.` and NOT
# exec. bin/agent-call.sh RUNS bin/iron-law-guard.sh, bin/run-build.sh runs
# bin/size-scope.sh, bin/run-triage.sh runs bin/overlap-guard.sh — a change to a
# callee does not pull in the suites that only name the caller. Many of those
# suites stub the callee, so following exec would widen the selection for little
# gain, and it is out of the ticket's stated design. It is written down here
# rather than left to be rediscovered: the safe reading of a small selection is
# "the map knows about `source`", not "nothing else can be affected".
ti_source_edges() {
  local idx="$1"
  ( cd "$ROOT" && grep -REHn '^[[:space:]]*(\.|source)[[:space:]]|shellcheck source=' \
      --include='*.sh' --include='*.bash' bin cron fly checks guardrails 2>/dev/null ) |
  awk -F: -v idxfile="$idx" "$TI_AWK_INDEX"'
    FILENAME == idxfile { FILE_[$0] = 1; adddirs($0); next }
    {
      script = $1
      line = $0
      sub(/^[^:]*:[0-9]*:/, "", line)
      gsub(/\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/, " ", line)
      n = split(line, w, /[^A-Za-z0-9._\/@+-]+/)
      sd = substr(script, 1, lastslash(script))
      for (i = 1; i <= n; i++) {
        t = w[i]
        if (t == "" || t !~ /\//) continue
        sub(/^[.\/]+/, "", t)
        if (t == "" || t !~ /\//) continue
        # A candidate is either a script file or a directory of them.
        for (j = 0; j < 2; j++) {
          cand = (j == 0) ? t : sd t
          if (isfile(cand) && cand ~ /\.(sh|bash|py|mjs|js)$/) { print script "\t" cand; break }
          d = asdir(cand)
          if (d != "" && d != "bin/" && d != "cron/" && d != "fly/") { print script "\t" d; break }
        }
      }
    }
  ' "$idx" - | LC_ALL=C sort -u
}

# ti_closure <edges> — the same edges, closed transitively, self included.
# A cycle (two libs that source each other) terminates because a pair already
# in the set is never added twice; the fixpoint is at most the number of edges.
ti_closure() {
  awk -F'\t' '
    { dep[$1, $2] = 1; from[$1] = from[$1] "\t" $2; keys[$1] = 1 }
    END {
      changed = 1
      while (changed) {
        changed = 0
        for (k in keys) {
          n = split(from[k], a, "\t")
          for (i = 1; i <= n; i++) {
            if (a[i] == "") continue
            if (!(a[i] in keys)) continue
            m = split(from[a[i]], b, "\t")
            for (j = 1; j <= m; j++) {
              if (b[j] == "" || ((k SUBSEP b[j]) in dep)) continue
              dep[k, b[j]] = 1; from[k] = from[k] "\t" b[j]; changed = 1
            }
          }
        }
      }
      for (kv in dep) { split(kv, p, SUBSEP); print p[1] "\t" p[2] }
    }
  ' "$1" | LC_ALL=C sort -u
}

# ── the always-run set ──────────────────────────────────────────────────────
# A suite that reads the WHOLE TREE has no useful map: whatever changed, it
# looked at it. Those are detected from their own text rather than listed by
# hand, because a list is a thing somebody forgets to add to and the failure
# mode of forgetting is a suite that stops running behind a green check.
#
# The four signals, all repo-rooted:
#   git … ls-files        the tree as git has it (ratchets, marker sweeps), with
#                         no pathspec or a pathspec of `.`; global options in
#                         between are allowed, so `git -C "$DIR" ls-files`
#                         counts and `git ls-files catalog` does not
#   find "$DIR"           the tree as the filesystem has it
#   --tree                bin/checks-run.sh --tree . — the whole-tree lane
#   "$DIR"/tests/*        a suite whose subject is the corpus itself
#
# ONLY ON TEXT THAT RUNS (BH-4551). The detector used to be one grep of each
# whole file for a bare `ls-files`, so a comment, a git stub's `"ls-files")`
# arm or `bad "… git ls-files …"` put a suite in the set — and on 2026-10-04 two
# suites landed there with no durations row and turned fast-lints-data D1-D3
# red in the merge queue. TI_ALWAYS_AWK reads each suite line by line: a line
# whose first non-blank byte is `#` is skipped (a trailing `# …` is not stripped,
# because `${#x}` and '#' make that unsafe), a leading case-arm pattern is
# stripped, and quoted text is masked — a single-quoted body always, a
# double-quoted one unless it holds a `$`, so `"$(git -C "$R" ls-files -u)"` and
# `find "$DIR/bin"` still count. A heredoc body is read like any other line.
# It prints each suite's FIRST matching line, which `always-why` hands back.
#
# catalog/test-impact-always.txt adds the ones no signal can see; it is one line
# per suite with a reason, and tests/test-impact-test.sh asserts the families
# BH-1203 named are in the set by one route or the other.
#
# No regex intervals (`{n}`): mawk.
TI_ALWAYS_AWK='
# mask — empty the quoted text of a line, keeping the quotes. A double-quoted
# body that holds a $ is an argument and stays, $( … ) copied through whole.
function mask(s,   o, i, c, j, q, d, ch) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") { o = o substr(s, i, 2); i++; continue }
    if (c == "\047" || c == "\"") {
      j = i + 1; q = ""
      while (j <= length(s) && substr(s, j, 1) != c) {
        if (c == "\"" && substr(s, j, 1) == "\\") { q = q substr(s, j, 2); j += 2; continue }
        if (c == "\"" && substr(s, j, 2) == "$(") {
          d = 0; q = q "$"; j++
          do { ch = substr(s, j, 1); if (ch == "(") d++; else if (ch == ")") d--; q = q ch; j++ } while (j <= length(s) && d > 0)
          continue
        }
        q = q substr(s, j, 1); j++
      }
      o = o c ((c == "\"" && index(q, "$") > 0) ? q : "") c
      i = j; continue
    }
    o = o c
  }
  return o
}
BEGIN {
  CASEARM = "^[[:space:]]*\\(?(\"[^\"]*\"|\047[^\047]*\047|[^[:space:]()\"\047$;])+\\)"
  FINDRE = "find[[:space:]]+\"?\\$\\{?(" ROOTVAR_ ")\\}?\"?"
  GLOBRE = "\\$\\{?(" ROOTVAR_ ")\\}?\"?/tests/\\*"
}
FILENAME in done_ { next }
/^[[:space:]]*#/ { next }
{
  s = $0
  sub(CASEARM, "", s)
  s = mask(s); hit = 0
  # git [global opts] ls-files, then words up to the end of the command: any
  # word that is not --, . or an option is a pathspec, so scoped. Redirects
  # (`2>/dev/null`, `>"$T/all"`, `2>&1`) go first, target and all, because the
  # cut at the end of the command would otherwise stop on their `>` and leave
  # the fd number behind as a pathspec.
  t = s
  while (!hit && match(t, /(^|[^[:alnum:]_.\/-])git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+ls-files/)) {
    rest = substr(t, RSTART + RLENGTH); t = rest
    if (rest !~ /^([[:space:]]|$|[;|&)<>`])/) continue
    gsub(/[0-9]*(>>?|<)&?[[:space:]]*[^[:space:];|&)<>`]*/, " ", rest)
    sub(/[;|&)<>`].*$/, "", rest)
    n = split(rest, a, /[[:space:]]+/); scoped = 0
    for (i = 1; i <= n; i++)
      if (a[i] != "" && a[i] != "--" && a[i] != "." && a[i] !~ /^-/) scoped = 1
    if (!scoped) hit = 1
  }
  if (s ~ /(^|[[:space:]])--tree([[:space:]=]|$)/ || s ~ FINDRE || s ~ GLOBRE) hit = 1
  if (hit) { done_[FILENAME] = 1; print FILENAME "\t" FNR "\t" $0 }
}
'

# ti_always_why — `<suite>\t<source>`, one row per always-run suite, sorted.
# <source> is `tests/x.sh:<n>: <the line>` for a detected suite (leading blanks
# trimmed, cut at 160 bytes) or catalog/test-impact-always.txt for a listed
# one; a suite that is both gets its detected row. A scan that dies is rc 2 with
# its stderr intact — never a short set, which fast-lints would read as fewer
# suites to run and ti_build_map as a map with fewer `*` rows.
ti_always_why() {
  local extra="$ROOT/catalog/test-impact-always.txt" tab=$'\t' s src _files=()
  while IFS= read -r s; do [ -n "$s" ] && _files+=("$s"); done < <(ti_suites)
  if [ "${#_files[@]}" -gt 0 ]; then
    ( cd "$ROOT" && LC_ALL=C awk -v ROOTVAR_="$TI_ROOTVAR" "$TI_ALWAYS_AWK" "${_files[@]}" ) > "$TI_TMP/always-hits" || {
      echo "test-impact: the always-run scan failed — refusing to hand back a short set" >&2
      return 2
    }
  else
    : > "$TI_TMP/always-hits"
  fi
  {
    LC_ALL=C awk -F'\t' '{
      l = $0; sub(/^[^\t]*\t[^\t]*\t/, "", l); sub(/^[ \t]+/, "", l)
      print $1 "\t" $1 ":" $2 ": " substr(l, 1, 160)
    }' "$TI_TMP/always-hits"
    if [ -r "$extra" ]; then
      { grep -Ev '^[[:space:]]*(#|$)' "$extra" || :; } | awk '{print $1 "\tcatalog/test-impact-always.txt"}'
    fi
  } | LC_ALL=C sort -s -t "$tab" -k1,1 | awk -F'\t' '!seen[$1]++' | while IFS="$tab" read -r s src; do
    if [ -n "$s" ] && [ -f "$ROOT/$s" ]; then printf '%s\t%s\n' "$s" "$src"; fi
  done
}

ti_always() {
  ti_always_why | cut -f1
}

# ti_learned_rows — `<suite>\t<path>` for each data line of each
# catalog/test-impact-learned.d/*.tsv. bin/impact-learn.sh writes one fragment
# per edge, `<path>\t<suite>\t<source batch>\t<date>`, when a merge-queue batch
# failed suite <suite> for a culprit that changed <path> and the map did not
# select it. <path> is a file, a directory row that ends in `/`, or `*` (a
# whole-repo suite: an always row). A row whose suite or path is not in the tree
# is dropped, the same rule as catalog/test-impact-always.txt: a rename must not
# leave a phantom row. No directory or no fragment is 0 rows. A fragment awk
# cannot read is rc 2, never a short map.
ti_learned_rows() {
  local dir="$ROOT/catalog/test-impact-learned.d" f s p frags=()
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.tsv; do
    if [ -e "$f" ] || [ -L "$f" ]; then frags+=("$f"); fi
  done
  [ "${#frags[@]}" -gt 0 ] || return 0
  LC_ALL=C awk -F'\t' '/^[ \t]*(#|$)/ { next } NF >= 2 && $1 != "" && $2 != "" { print $2 "\t" $1 }' \
      "${frags[@]}" > "$TI_TMP/learned" || {
    echo "test-impact: a learned edge fragment could not be read — refusing to hand back a short map" >&2
    return 2
  }
  while IFS=$'\t' read -r s p; do
    [[ "$s" =~ ^tests/(mc/)?[A-Za-z0-9._-]+\.sh$ ]] && [ -f "$ROOT/$s" ] || continue
    case "$p" in
      '*') ;;
      */) [ -d "$ROOT/$p" ] || continue ;;
      *)  [ -f "$ROOT/$p" ] || continue ;;
    esac
    printf '%s\t%s\n' "$s" "$p"
  done < "$TI_TMP/learned"
}

# ti_treedir_rows — `<suite>\t<dir>/` for a suite that scans a whole source
# directory with a BARE name (BH-6688 fix round). The path extractor drops a
# bare directory token on purpose: `the bin/ lane` in prose is not a
# dependency, and only a rooted token may name a directory. A whole-directory
# SCAN is the exception, and the one that left #6355 out of draft #6367's
# candidates: tests/ticket-branch-ratchet.bh-3835-test.sh runs
# `( cd "$1" && grep -rnI … bin/ )`, so it had no bin/ row and no `*` row, and
# a change to bin/lib/stall-alerts.sh never reached it.
#
# The two signals, on code lines only (a `#`-led line is skipped and quoted
# text is masked the way TI_ALWAYS_AWK masks it, so a pattern 'bin/' is not a
# directory):
#   grep -r / -R / --recursive, or rg   every word on that line that is a bare
#                                        or rooted top-level source directory
#                                        (bin, bin/, fly, "$DIR/worker", …)
#   os.walk + os.path.join(x, "<dir>")  a python walk of that directory
# A word behind any other variable (`"$T/bin"`) is a scratch path and adds
# nothing. A directory row is a root row for bin/ (ti_root_rows), so it never
# makes a path "specific", and the orphan list counts exact rows only.
# Over-matching runs one extra suite on a change under that directory, the
# documented safe direction. A word that names a FILE is an exact row; a path
# the tree does not hold adds no row.
TI_TREEDIR_AWK='
function mask(s,   o, i, c, j, q) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") { o = o substr(s, i, 2); i++; continue }
    if (c == "\047" || c == "\"") {
      j = i + 1; q = ""
      while (j <= length(s) && substr(s, j, 1) != c) { q = q substr(s, j, 1); j++ }
      o = o c ((c == "\"" && index(q, "$") > 0) ? q : "") c
      i = j; continue
    }
    o = o c
  }
  return o
}
BEGIN {
  DIRRE = "^(" DIRS_ ")(/[A-Za-z0-9._-]+)*/?$"
  ROOTRE = "^\\$\\{?(" ROOTVAR_ ")\\}?/"
}
/^[[:space:]]*#/ { next }
{
  s = mask($0)
  if (s ~ /(^|[^A-Za-z0-9_-])grep[[:space:]]+([^|;&]*[[:space:]])?(-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]|$)/ || s ~ /(^|[^A-Za-z0-9_-])rg[[:space:]]/) {
    n = split(s, w, /[[:space:];|&()`<>]+/)
    for (i = 1; i <= n; i++) {
      t = w[i]; gsub(/"/, "", t)
      if (t ~ ROOTRE) sub(ROOTRE, "", t)
      else if (t ~ /\$/) continue
      if (t ~ DIRRE) { sub(/\/$/, "", t); print FILENAME "\t" t "/" }
    }
  }
}
'
# The python walk: a file that calls os.walk, and a line that joins a root with
# a quoted source directory name.
TI_TREEDIR_PY_AWK='
/^[[:space:]]*#/ { next }
{
  s = $0
  while (match(s, /os\.path\.join\([A-Za-z_][A-Za-z0-9_]*,[[:space:]]*"[A-Za-z0-9._-]+"\)/)) {
    m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    sub(/^[^"]*"/, "", m); sub(/".*$/, "", m)
    if (m ~ "^(" DIRS_ ")$") print FILENAME "\t" m "/"
  }
}
'
ti_treedir_rows() {
  local dirs='bin|worker|console-ui|mcp|agent-core|locks-worker|cron|catalog|env-templates|guardrails|checks|prompts|fly|config|rules|skills|orchestrator|tasks|docs'
  local _s _files=() _walk=() s p
  while IFS= read -r _s; do [ -n "$_s" ] && _files+=("$_s"); done < <(ti_suites)
  [ "${#_files[@]}" -gt 0 ] || return 0
  for _s in "${_files[@]}"; do grep -q 'os\.walk' "$ROOT/$_s" 2>/dev/null && _walk+=("$_s"); done
  {
    ( cd "$ROOT" && LC_ALL=C awk -v ROOTVAR_="$TI_ROOTVAR" -v DIRS_="$dirs" "$TI_TREEDIR_AWK" "${_files[@]}" ) || return 2
    if [ "${#_walk[@]}" -gt 0 ]; then
      ( cd "$ROOT" && LC_ALL=C awk -v DIRS_="$dirs" "$TI_TREEDIR_PY_AWK" "${_walk[@]}" ) || return 2
    fi
  } > "$TI_TMP/treedir" || {
    echo "test-impact: the whole-directory scan failed — refusing to hand back a short map" >&2
    return 2
  }
  # A directory is a `<dir>/` row. A FILE the scan named (`grep -r x
  # bin/jobs-client.sh`) is an exact row, the row the path extractor gives a
  # named file. Anything else names nothing in this tree and adds no row. The
  # loop's last test must never be the function's status: a missing path on
  # the last sorted row would turn a good scan into rc 1 and the map into rc 2.
  LC_ALL=C sort -u "$TI_TMP/treedir" | while IFS=$'\t' read -r s p; do
    p="${p%/}"
    if [ -d "$ROOT/$p" ]; then printf '%s\t%s/\n' "$s" "$p"
    elif [ -f "$ROOT/$p" ]; then printf '%s\t%s\n' "$s" "$p"
    fi
  done
  return 0
}

# ── the map ─────────────────────────────────────────────────────────────────
ti_build_map() {
  local idx="$TI_TMP/index" edges="$TI_TMP/edges" closed="$TI_TMP/closed"
  # THE SUITE LIST FIRST, and the refusal with it. Everything below hands it to
  # awk as an argv, and awk with an EMPTY argv reads stdin — so this refusal
  # standing after the first awk call is the difference between "rc 2, no suites
  # under tests/" and a run that blocks until something kills it (BH-1253).
  local _s _files=()
  while IFS= read -r _s; do [ -n "$_s" ] && _files+=("$_s"); done < <(ti_suites)
  [ "${#_files[@]}" -gt 0 ] || { echo "test-impact: no suites under tests/ in $ROOT" >&2; return 2; }

  ti_files > "$idx"
  [ -s "$idx" ] || { echo "test-impact: $ROOT holds no files — refusing to build a map of nothing" >&2; return 2; }
  ti_source_edges "$idx" > "$edges"
  ti_closure "$edges" > "$closed"

  ti_rootvars "${_files[@]}" > "$TI_TMP/rootvars"

  # Every suite depends on itself, and the whole-tree suites depend on all of it.
  {
    ti_suites | awk '{print $0 "\t" $0}'
    ti_always | awk '{print $0 "\t*"}'
  } > "$TI_TMP/raw" || return 2
  # The edges a merge-queue failure taught the map (ti_learned_rows). The copy
  # in learned.rows is what ti_why_rows reads to print the `learned` kind.
  ti_learned_rows > "$TI_TMP/learned.rows" || return 2
  cat "$TI_TMP/learned.rows" >> "$TI_TMP/raw" || return 2
  # A suite that scans a whole source directory by its bare name (ti_treedir_rows).
  ti_treedir_rows >> "$TI_TMP/raw" || return 2

  # Literal paths and rooted globs, out of NORMALISED lines. One pass over the
  # corpus, one form of the checkout root to recognise — see TI_AWK_NORM.
  #
  # LC_ALL=C, AND THE ERROR IS NOT SWALLOWED. Observed ONCE, on one Mac, while a
  # POSIX character class was in the scan pattern: awk went multibyte, hit an
  # invalid byte in one suite, aborted the whole run — and because the scan's
  # stderr went to /dev/null the map came back 3,117 rows short with no
  # complaint. It did not reproduce afterwards and it has not been reproduced on
  # another machine, so treat the abort as a one-off rather than a known bug.
  # Both guards stay regardless, because the SHAPE is what matters and it is the
  # one this lane exists to refuse: a scan that quietly returns less. The class
  # is gone, the locale is pinned so no future pattern can put awk back into
  # that mode, and a scan that dies fails the build, which selects everything.
  # The suite list is built at the top of this function, not left to a glob in
  # awk's argv: tests/mc/ holds no .sh yet, and an unmatched glob reaches awk as
  # a filename it cannot open — which is now, correctly, a hard failure rather
  # than a silent short map.
  #
  # NOCOMMENT_ is the ORPHAN RATCHET's reading of the corpus and nothing else
  # (see ti_orphans). Unset — which is every other caller, `select`, `ci-select`,
  # `audit` and a plain `map` — the scan is byte-for-byte what it always was.
  if ! ( cd "$ROOT" && LC_ALL=C awk -v idxfile="$TI_TMP/index" -v rvfile="$TI_TMP/rootvars" \
        -v ROOTVAR_="$TI_ROOTVAR" -v PFX_="$TI_PREFIX_AWK" \
        -v NOCOMMENT_="${TI_ORPHAN_STRICT:-0}" \
        "$TI_AWK_INDEX$TI_AWK_NORM"'
        BEGIN { TOK = "(@ROOT@/)?(" PFX_ ")(/[A-Za-z0-9._/@+*-]*)?" }
        FILENAME == idxfile { FILE_[$0] = 1; adddirs($0); next }
        FILENAME == rvfile  { if ($2 == "@PYARGV@") PY_[$1] = 1
                              # WRITTEN OUT, NOT A TERNARY, BECAUSE OF MAWK. In
                              # `RV_[x] = ((x in RV_) ? … : "") $2` mawk creates
                              # the array element for the LVALUE before it
                              # evaluates the right side, so `x in RV_` is true
                              # on first sight and rv starts with an empty
                              # alternative — `(|DIR|…)`, which mawk then
                              # refuses to compile and the whole map dies. mawk
                              # 1.3.4 is the awk on every fleet box and in the
                              # debian:trixie-slim gate of run-tests-in-docker.
                              else if ($1 in RV_) RV_[$1] = RV_[$1] "|" $2
                              else RV_[$1] = $2
                              next }
        {
          if (NOCOMMENT_ && $0 ~ /^[ \t]*#/) next
          line = ti_norm($0, FILENAME)
          while (match(line, TOK)) {
            st = RSTART; ln = RLENGTH
            tok = substr(line, st, ln)
            prev = (st > 1) ? substr(line, st - 1, 1) : ""
            line = substr(line, st + ln)
            if (substr(tok, 1, 7) == "@ROOT@/") { rooted = 1; tok = substr(tok, 8) }
            else {
              rooted = 0
              # An UNROOTED token has to start a word, or `robin/x` contributes
              # `bin/x`. It must also resolve to a real file: `the bin/ lane` in
              # a sentence is prose, and `$T/bin/x` is a scratch path this rule
              # is what keeps out.
              if (prev != "" && prev ~ /[\/A-Za-z0-9._@+$*{-]/) continue
            }
            sub(/[.,]+$/, "", tok)
            if (tok == "") continue
            if (index(tok, "*") > 0) {
              if (!rooted) continue
              sub(/[^\/]*\*.*$/, "", tok)   # the glob itself, back to its directory
              d = asdir(tok); if (d != "") print FILENAME "\t" d
              continue
            }
            if (isfile(tok)) { print FILENAME "\t" tok; continue }
            if (!rooted) continue
            d = asdir(tok); if (d != "") print FILENAME "\t" d
          }
        }
      ' "$TI_TMP/index" "$TI_TMP/rootvars" "${_files[@]}" ) >> "$TI_TMP/raw"; then
    echo "test-impact: the suite scan failed — refusing to hand back a short map" >&2
    return 2
  fi
  LC_ALL=C sort -u "$TI_TMP/raw" > "$TI_TMP/direct"

  # Close each suite's FILE rows over what those scripts source. A directory row
  # is expanded to its members for this purpose only — a change under bin/lib/rb/
  # has to pull in the suites that reach it through bin/run-build.sh.
  awk -F'\t' -v idxfile="$idx" -v closedfile="$closed" "$TI_AWK_INDEX"'
    FILENAME == idxfile   { FILE_[$0] = 1; adddirs($0); files[++nf] = $0; next }
    FILENAME == closedfile { dep[$1] = dep[$1] "\t" $2; next }
    {
      print
      if ($2 == "*") next
      if ($2 ~ /\/$/) {
        for (i = 1; i <= nf; i++) if (index(files[i], $2) == 1) emit($1, files[i])
      } else emit($1, $2)
    }
    function emit(suite, path,   n, a, i) {
      if (!(path in dep)) return
      n = split(dep[path], a, "\t")
      for (i = 1; i <= n; i++) if (a[i] != "") print suite "\t" a[i]
    }
  ' "$idx" "$closed" "$TI_TMP/direct" | LC_ALL=C sort -u
}

# ── selection ───────────────────────────────────────────────────────────────
# Paths that cannot reach any suite BY CONSTRUCTION. Everything else that the
# map does not cover is UNKNOWN REACH and runs the whole corpus, so this list is
# the only place a wrong entry can cost coverage — it is deliberately tiny and
# deliberately excludes docs/verification-map/, which real suites read.
# ti_inert <path> — true when a path cannot reach a suite by construction.
# Spelled as a function and not a PCRE because the one rule that needs a
# negative lookahead (docs/ but NOT docs/verification-map/) would need grep -P,
# and a grep that does not understand its own pattern exits 2 — which this code
# would read as "not inert", i.e. the whole corpus, forever, silently.
ti_inert() {
  case "$1" in
    docs/verification-map/*) return 1 ;;
    # .harness/specs/<TICKET>/plan.md is the PLAN stage's own artifact, one
    # directory per ticket, written by the pipeline and read by the gates at
    # build time. 42 of the last 60 merges carry one and no suite opens the real
    # tree, so leaving it unmapped would have spent a full corpus on seven PRs
    # in ten for a file that cannot change how any suite behaves.
    .harness/specs/*) return 0 ;;
    docs/*|.claude/*|LICENSE) return 0 ;;
    */*) return 1 ;;
    *.md) return 0 ;;
    *) return 1 ;;
  esac
}
# Infra: a change here can move which suites exist or how they run, so the map
# is not an authority on it. tests/lib/ is a library every suite may source
# (in the full list only, BH-6371: a batch select follows the helper closure);
# suite-runner.sh and this script ARE the selection; a workflow change is the
# thing being proved; catalog/ holds the conf the gates read. The three RUNNERS
# are here on the BH-1203 review's N1: the map would select their own suites and
# about seventy more, which is defensible, but a runner is the thing that
# decides whether a green ran anything at all — the one file where "the map says
# so" is not a good enough answer. They change rarely, so the corpus is cheap.
# bin/lib/docker-host.sh (BH-1193) is here for the same reason one level down:
# it decides WHERE a green ran — which daemon, and whether the container got the
# tree or an empty /repo.
# A batch select (TI_BATCH_SELECT=1, BH-6059) uses the core list without
# ^catalog/: bin/ci-plan.sh has already escalated on the catalogs the selection
# reads (catalog/ci-batch-escalate.tsv), and every other catalog/ path selects
# through the map or is unmapped. Every literal path here has an escalate row in
# that file (tests/ci-batch-escalate-narrow.bh-6059-test.sh G1). ^tests/lib/ is
# out of the core list too (BH-6371): the global helpers have escalate rows in
# that file, and every other helper selects through ti_testlib_closure. The full
# list, which the PR select and the builder gate read, is unchanged. ti_inputs
# reads the core list and decides tests/lib/ and catalog/ path by path
# (ti_inputs_infra, BH-6406).
ti_infra_core_re='^bin/suite-reuse\.sh$|^bin/lib/suite-fingerprint\.sh$|^bin/lib/suite-runner\.sh$|^bin/lib/docker-host\.sh$|^bin/test-impact\.sh$|^bin/test-suite-run\.sh$|^bin/test-trace-safety\.sh$|^bin/run-tests-in-docker\.sh$|^\.github/workflows/'
ti_infra_re="$ti_infra_core_re|^tests/lib/|^catalog/"
# The whole-tree scanner rows: almost every bin/ or catalog/ path is "covered"
# through them, so they say nothing about one path (BH-6059).
ti_root_rows=' bin/ bin/lib/ catalog/ '

# ti_reachable <map> <path> — is this changed path covered by a map row?
ti_covered() {
  awk -F'\t' -v p="$2" '
    $2 == "*" { next }
    $2 == p   { found = 1; exit }
    $2 ~ /\/$/ && index(p, $2) == 1 { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

# ti_specific <map> <path> — covered by a row other than a whole-tree root row?
ti_specific() {
  awk -F'\t' -v p="$2" -v roots="$ti_root_rows" '
    $2 == "*" || index(roots, " " $2 " ") > 0 { next }
    $2 == p   { found = 1; exit }
    $2 ~ /\/$/ && index(p, $2) == 1 { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

# ti_testlib_closure <path> — THE HELPER CLOSURE (BH-6371): <path>, plus every
# tests/lib/ file that names the basename of a file already in the set on a
# line that is not a comment, until no file is added. A suite that sources
# fixture-harness.sh reaches rb-all.sh through it, and the map has a row only
# for the helper the suite names. A basename match over-approximates on
# purpose: an extra suite runs, and no consumer is missed.
ti_testlib_closure() {
  local libs=() f
  while IFS= read -r f; do [ -f "$ROOT/$f" ] && libs+=("$f"); done \
    < <(cd "$ROOT" && ls -d tests/lib/* 2>/dev/null)
  if [ "${#libs[@]}" -eq 0 ]; then printf '%s\n' "$1"; return 0; fi
  # Each operand is ./<path>, for the reason ti_named_scan gives: a bare
  # name=value operand is an awk assignment, never a file.
  local _args=(); for f in "${libs[@]}"; do _args+=("./$f"); done
  ( cd "$ROOT" && LC_ALL=C awk -v start="$1" '
      function base(p) { sub(/.*\//, "", p); return p }
      FNR == 1 { n++; f = FILENAME; sub(/^\.\//, "", f); F[n] = f; T[n] = "" }
      /^[ \t]*#/ { next }
      { T[n] = T[n] "\n" $0 }
      END {
        inset[start] = 1; B[base(start)] = 1
        # Bounded: each round that continues adds at least one file.
        for (round = 0; round <= n; round++) {
          added = 0
          for (i = 1; i <= n; i++) {
            if (F[i] in inset) continue
            for (b in B) if (index(T[i], b) > 0) { inset[F[i]] = 1; NEW[F[i]] = 1; added = 1; break }
          }
          for (f in NEW) B[base(f)] = 1
          for (f in NEW) delete NEW[f]
          if (!added) break
        }
        for (f in inset) print f
      }' "${_args[@]}" ) | LC_ALL=C sort -u
}

# ti_testlib_edges — THE HELPER CLOSURE, DOWNWARD (BH-6406): `<a>\t<r>` for
# every tests/lib/ file a and every tracked tests/lib/ file r that a reaches,
# a itself included. a reaches r when a's non-comment text names r's basename,
# directly or through other helpers. It is the relation ti_testlib_closure
# follows upward, with the same files, basename rule and comment rule, so r is
# in the closure of a changed b exactly when a suite naming a reaches b here.
ti_testlib_edges() {
  local libs=() f tg="$TI_TMP/edges.targets"
  ti_files > "$TI_TMP/edges.files" || return 2
  awk '/^tests\/lib\//' "$TI_TMP/edges.files" > "$tg"
  while IFS= read -r f; do [ -f "$ROOT/$f" ] && libs+=("$f"); done \
    < <(cd "$ROOT" && ls -d tests/lib/* 2>/dev/null)
  {
    awk '{ print $0 "\t" $0 }' "$tg"
    if [ "${#libs[@]}" -gt 0 ]; then
      # ./<path> operands, for the reason ti_named_scan gives.
      local _args=(); for f in "${libs[@]}"; do _args+=("./$f"); done
      ( cd "$ROOT" && LC_ALL=C awk -v tf="$tg" '
          function base(p) { sub(/.*\//, "", p); return p }
          BEGIN { while ((getline t < tf) > 0) { m++; R[m] = t; RB[m] = base(t) } }
          FNR == 1 { n++; f = FILENAME; sub(/^\.\//, "", f); F[n] = f; T[n] = "" }
          /^[ \t]*#/ { next }
          { T[n] = T[n] "\n" $0 }
          END {
            for (i = 1; i <= n; i++) {
              print F[i] "\t" F[i]
              for (j = 1; j <= m; j++) if (R[j] != F[i] && index(T[i], RB[j]) > 0) print F[i] "\t" R[j]
            }
          }' "${_args[@]}" ) || return 2
    fi
  } > "$TI_TMP/edges" || return 2
  ti_closure "$TI_TMP/edges"
}

# ti_testlib_mapped <map> <closure-file> — rc 0 when a map row names one of the
# closure's files exactly. The tests/lib/ directory row (suites that scan the
# whole directory) matches every helper, so it is no proof of a consumer.
ti_testlib_mapped() {
  awk -F'\t' 'FILENAME == ARGV[1] { if ($0 != "") want[$0] = 1; next }
    ($2 in want) { found = 1; exit }
    END { exit(found ? 0 : 1) }' "$2" "$1"
}

# ── THE WHY COLUMN (BH-1524) ────────────────────────────────────────────────
# `select --why` prints one `<suite>\t<kind>\t<path>` row per reason a suite was
# picked, so a reviewer reading a gate table can see that the pinned suites ran
# and why. The kinds, strongest first:
#
#   self     the diff changed the suite itself
#   reads    the suite names the path on a line that READS it as data — grep,
#            sed, awk, diff, cat, wc, jq … over it, with nothing on that line
#            running or sourcing it. The pins live here: tests/launch-fastpath's
#            T1.32 diffs a copy of bin/orphan-reconcile.sh's regex block.
#   named    the suite names a FUNCTION defined in a changed script, at the base
#            or the head (<path>#<function>). See ti_named_rows.
#   source   the suite names the path on a line that runs, sources or copies it
#   learned  a learned edge (catalog/test-impact-learned.d/, BH-6459) names the
#            path for the suite, and the suite text does not name it. The gate
#            ranks it directly above closure.
#   closure  the suite reaches the path only through what its scripts `source`
#   always   the suite is in the always-run set (<path> is `*`)
#   full     the whole corpus was selected; <path> is the reason
#
# THE ORIGIN OF THIS COLUMN, because it corrects the ticket that asked for it.
# BH-1524 read four extra review rounds as this script failing to select a
# pinned suite. Replayed, every one of those diffs selected the suite that went
# red, on main's map and on each PR's own tree's map, and the suites went red in
# CI — which is the lane working. What had NOT run them was the builder, whose
# gate table was hand-picked; bin/test-impact-gate.sh is what closes that, and
# this column is what lets its table show the pins.
#
# reads vs source is decided by the verbs on the naming line, nothing cleverer.
# The line `sed … "$DIR/bin/x.sh" > "$T/x.sh"; bash "$T/x.sh"` says both and
# reads as source — the conservative answer, since the gate ranks reads first.
TI_READ_RE='(^|[^A-Za-z0-9_.-])(grep|egrep|fgrep|rg|sed|awk|gawk|mawk|diff|cmp|cat|wc|jq|head|tail|sort|comm|cut|md5sum|sha1sum|sha256sum|shasum)([ \t]|$)|open[(]'
# A line that writes what it read into a file (`sed … "$DIR/bin/x.sh" >
# "$H/bin/x.sh"`) is making a copy to run, so it is source, not a read.
TI_RUN_RE='(^|[^A-Za-z0-9_.-])(source|bash|sh|exec|cp|install|ln|chmod|python|python3)[ \t]|^[ \t]*[.][ \t]|>[ \t]*"?[$]'

# ti_why_rows <map> <changed> — `<suite>\t<kind>\t<path>`, every reason, sorted.
ti_why_rows() {
  local map="$1" changed="$2" pairs="$TI_TMP/why.pairs" _s
  # A NARROWED path (a batch's bin/lib/ or catalog/ doc, BH-6059) never selects
  # through a whole-tree root row, only through a row that names it or its own
  # directory.
  [ -f "$TI_TMP/narrow" ] || : > "$TI_TMP/narrow"
  # The learned rows ti_build_map kept. With --map <file> the map was built
  # elsewhere and ti_build_map did not run here, so read them now. Only the
  # label depends on them: the selection comes from the map either way.
  if [ ! -f "$TI_TMP/learned.rows" ]; then
    ti_learned_rows > "$TI_TMP/learned.rows" 2>/dev/null || {
      : > "$TI_TMP/learned.rows"
      echo "test-impact: learned rows unreadable — learned picks print as closure" >&2
    }
  fi
  awk -F'\t' -v cf="$changed" -v nf="$TI_TMP/narrow" -v roots="$ti_root_rows" '
    FILENAME == nf { if ($0 != "") nar[$0] = 1; next }
    FILENAME == cf { if ($0 != "") ch[++nc] = $0; next }
    $2 == "*" { print $1 "\talways\t*\t*"; next }
    { for (i = 1; i <= nc; i++)
        if ($2 == ch[i] || ($2 ~ /\/$/ && index(ch[i], $2) == 1)) {
          if ((ch[i] in nar) && index(roots, " " $2 " ") > 0) continue
          print $1 "\t" ($1 == ch[i] ? "self" : "path") "\t" $2 "\t" ch[i] } }
  ' "$TI_TMP/narrow" "$changed" "$map" | LC_ALL=C sort -u > "$pairs"
  awk -F'\t' '$2 == "always" { print $1 "\talways\t*" } $2 == "self" { print $1 "\tself\t" $4 }' "$pairs"
  local files=()
  while IFS= read -r _s; do [ -n "$_s" ] && files+=("$_s"); done \
    < <(awk -F'\t' '$2 == "path" { print $1 }' "$pairs" | LC_ALL=C sort -u)
  if [ "${#files[@]}" -gt 0 ]; then
    # One pass over the picked suites' text, NORMALISED the way the map's own
    # scan normalises it, so "the suite names this path" means what it means
    # there: the checkout-rooted spelling (`@ROOT@/bin/x.sh`) or a bare token
    # that starts a word. A literal substring search would read `"$T/bin/x.sh"`
    # — the suite's own scratch copy — as naming the repo's bin/, which is the
    # exact confusion the map's extractor exists to refuse. A row path the
    # suite never spells out came in through the source closure.
    ti_rootvars "${files[@]}" > "$TI_TMP/why.rootvars"
    ( cd "$ROOT" && LC_ALL=C awk -v lf="$TI_TMP/learned.rows" -v pf="$pairs" -v rvfile="$TI_TMP/why.rootvars" \
        -v ROOTVAR_="$TI_ROOTVAR" -v RR="$TI_READ_RE" -v XR="$TI_RUN_RE" "$TI_AWK_NORM"'
        FILENAME == lf { split($0, f, "\t"); L[f[1] "\t" f[2]] = 1; next }
        FILENAME == pf { split($0, f, "\t")
                         if (f[2] == "path") { k = ++np; S[k] = f[1]; P[k] = f[3]; C[k] = f[4]; by[f[1]] = by[f[1]] " " k }
                         next }
        FILENAME == rvfile { split($0, f, "\t")
                             # mawk: no ternary on an element being created
                             # (the note at the same spot in ti_build_map).
                             if (f[2] == "@PYARGV@") PY_[f[1]] = 1
                             else if (f[1] in RV_) RV_[f[1]] = RV_[f[1]] "|" f[2]
                             else RV_[f[1]] = f[2]
                             next }
        { n = split(by[FILENAME], ids, " "); if (n == 0) next
          ln = ti_norm($0, FILENAME)
          for (j = 1; j <= n; j++) { k = ids[j]
            # READS needs the line to spell the CHANGED file. A directory row
            # (`cp "$DIR/bin/$f"`) names the directory, not this file, so it
            # is a direct dependency and never a pin on this file.
            if (names(ln, C[k])) { d[k] = 1; if (ln ~ RR && ln !~ XR) r[k] = 1 }
            else if (P[k] != C[k] && names(ln, P[k])) d[k] = 1 } }
        function names(ln, p,   i, rest, off, pre) {
          if (index(ln, "@ROOT@/" p) > 0) return 1
          rest = ln; off = 0
          while ((i = index(rest, p)) > 0) {
            pre = (off + i > 1) ? substr(ln, off + i - 1, 1) : ""
            if (pre == "" || pre !~ /[\/A-Za-z0-9._@+$*{-]/) return 1
            off += i; rest = substr(rest, i + 1)
          }
          return 0
        }
        END { for (k = 1; k <= np; k++)
                print S[k] "\t" (r[k] ? "reads" : (d[k] ? "source" : (((S[k] "\t" P[k]) in L) ? "learned" : "closure"))) "\t" C[k] }
      ' "$TI_TMP/learned.rows" "$pairs" "$TI_TMP/why.rootvars" "${files[@]}" )
  fi
  ti_named_rows "$changed"
}

# ti_named_rows <changed> — suites that name a function a changed script
# DEFINES, at the head or at the base (TI_NAMED_BASE). The base half is the one
# that matters most: a caller-count pin goes red when a function is renamed or
# deleted, and the head no longer defines the name its callers still spell.
#
# A NAME COUNTS ONLY WITH AN UNDERSCORE AND SIX CHARACTERS. `ok`, `bad`, `die`
# and `log` are defined in half the scripts here and spelled in every suite; a
# name that short selects the corpus and says nothing. The fleet's function
# names are namespaced (br_close_pr, mc_hold_keeps_pr) and those are the ones a
# pin names. tests/ is skipped: a changed suite already selects itself.
# The definition filter, shared with ti_inputs: a line that defines a shell
# function prints `<p>\t<name>` when the name passes the rule above.
TI_AWK_DEFS='
/^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*[(][ \t]*[)]/ || /^[ \t]*function[ \t]+[A-Za-z_]/ {
  nm = $0; sub(/^[ \t]*/, "", nm); sub(/^function[ \t]+/, "", nm); sub(/[^A-Za-z0-9_].*$/, "", nm)
  if (index(nm, "_") > 0 && length(nm) >= 6) print (p != "" ? p : FILENAME) "\t" nm }'
ti_named_rows() {
  local changed="$1" defs="$TI_TMP/named.defs" p
  : > "$defs"
  while IFS= read -r p; do
    case "$p" in tests/*|'') continue ;; *.sh|*.bash) ;; *) continue ;; esac
    { [ -f "$ROOT/$p" ] && cat "$ROOT/$p"
      [ -n "${TI_NAMED_BASE:-}" ] && git -C "$ROOT" show "$TI_NAMED_BASE:$p" 2>/dev/null
    } | LC_ALL=C awk -v p="$p" "$TI_AWK_DEFS" >> "$defs"
  done < "$changed"
  ti_named_scan "$defs"
}

# ti_named_scan <defs> — the suite half of ti_named_rows: every suite that
# spells a name in <defs> (`<path>\t<name>` rows), as `<suite>\tnamed\t<path>#<name>`.
ti_named_scan() {
  local defs="$1" names="$TI_TMP/named.names" p
  [ -s "$defs" ] || return 0
  cut -f2 "$defs" | LC_ALL=C sort -u > "$names"
  local suites=()
  while IFS= read -r p; do [ -n "$p" ] && suites+=("$p"); done < <(ti_suites)
  [ "${#suites[@]}" -gt 0 ] || return 0
  # COMMENT LINES DO NOT COUNT (BH-1554 / the #1541 round-2 review: three of six
  # `named` picks were suites whose only mention of the name was a comment, and
  # a comment cannot go red when the function changes). Full-line comments are
  # skipped; a trailing comment on a line that RUNS still counts, which is the
  # conservative answer.
  #
  # ONE awk pass over all of them, not `sed | grep` per suite: the corpus is
  # 700+ suites and a fork pair each is 1400 processes on the gate's critical
  # path (BH-1554 review, advisory 3). Matching is by TOKEN, not regex: each
  # line's non-word bytes become separators and every token is looked up in the
  # names set, which is exactly `grep -owF`'s whole-word semantics for names
  # that are themselves [A-Za-z0-9_]+ — and ti_named_rows above truncates every
  # name at its first non-word byte, so they always are.
  # Each suite is passed as ./<path>. awk has no `--` and a bare operand of the
  # form name=value is a VARIABLE ASSIGNMENT, not a file: awk never opens it and
  # the suite would leave the selection with no error anywhere. Today's paths
  # cannot hit that (the name part must be a valid awk identifier and
  # `tests/...` is not one), so this is belt and braces against a future shape
  # that passes basenames or runs from inside tests/. The prefix is stripped
  # back off FILENAME on output so the rows downstream carry the same paths
  # ti_suites printed.
  local _args=(); local _s
  for _s in "${suites[@]}"; do _args+=("./$_s"); done
  ( cd "$ROOT" && LC_ALL=C awk -v nf="$names" '
      BEGIN { while ((getline n < nf) > 0) if (n != "") want[n] = 1 }
      FNR == 1 { delete seen; f = FILENAME; sub(/^\.\//, "", f) }
      /^[ \t]*#/ { next }
      { line = $0; gsub(/[^A-Za-z0-9_]/, " ", line); k = split(line, tok, " ")
        for (i = 1; i <= k; i++)
          if ((tok[i] in want) && !(tok[i] in seen)) { seen[tok[i]] = 1; print f ":" tok[i] } }
    ' "${_args[@]}" 2>/dev/null ) | LC_ALL=C sort -u |
    awk -F'\t' -v df="$defs" '
      FILENAME == df { at[$2] = at[$2] "\t" $1; next }
      { i = index($0, ":"); s = substr($0, 1, i - 1); nm = substr($0, i + 1)
        n = split(at[nm], ps, "\t"); for (j = 1; j <= n; j++) if (ps[j] != "") print s "\tnamed\t" ps[j] "#" nm }
    ' "$defs" -
}

# ── inputs (BH-5366) ────────────────────────────────────────────────────────
# ti_inputs — everything each suite READS, for bin/lib/suite-fingerprint.sh:
# every map row as it is (`<suite>\t<suite>`, `<suite>\t*`, `<suite>\t<path>`),
# a `<suite>\t<path>` row for every function a suite names that a non-test
# script defines (the `named` rule, over the whole tree rather than a diff),
# a `<suite>\t<helper>` row for every tests/lib/ helper a named helper reaches
# (ti_testlib_edges, BH-6406), and `@infra\t<path>` for every file
# ti_inputs_infra says the map cannot speak for.
# Over-approximate on purpose: an extra input costs a re-run, a missing one a
# reuse that should not have happened. A map that cannot be built is rc 2.
ti_inputs() {
  local map="$TI_TMP/inputs.map" files="$TI_TMP/inputs.files" defs="$TI_TMP/inputs.defs"
  ti_build_map > "$map" || return 2
  [ -s "$map" ] || { echo "test-impact: the map came back empty" >&2; return 2; }
  ti_files > "$files" || return 2
  local scripts=() p
  while IFS= read -r p; do
    case "$p" in tests/*) ;; *.sh|*.bash) [ -f "$ROOT/$p" ] && scripts+=("$p") ;; esac
  done < "$files"
  : > "$defs"
  if [ "${#scripts[@]}" -gt 0 ]; then
    ( cd "$ROOT" && LC_ALL=C awk -v p="" "$TI_AWK_DEFS" "${scripts[@]}" ) > "$defs" || {
      echo "test-impact: the function scan failed" >&2; return 2; }
  fi
  # The named scan runs on its own, status checked: inside the group below its
  # rc would be lost, and a scan that died is every named edge gone with rc 0,
  # a short list that lets a suite be reused across a named function's change.
  local named="$TI_TMP/inputs.named"
  ti_named_scan "$defs" > "$named" || { echo "test-impact: the named-function scan failed" >&2; return 2; }
  # The helper rows: a suite whose map row names helper h reads every helper
  # h reaches (ti_testlib_edges). A scan that died is rc 2, never a short list.
  local closed="$TI_TMP/inputs.closed" helpers="$TI_TMP/inputs.helpers"
  ti_testlib_edges > "$closed" || { echo "test-impact: the helper closure failed" >&2; return 2; }
  awk -F'\t' 'FILENAME == ARGV[1] { to[$1] = to[$1] "\t" $2; next }
    $2 ~ /^tests\/lib\// && ($2 in to) { n = split(to[$2], r, "\t"); for (i = 2; i <= n; i++) print $1 "\t" r[i] }
  ' "$closed" "$map" > "$helpers" || { echo "test-impact: the helper rows failed" >&2; return 2; }
  ti_inputs_infra "$map" "$helpers" "$files" > "$TI_TMP/inputs.infra" || return 2
  {
    cat "$map" "$helpers"
    awk -F'\t' '{ sub(/#[^#]*$/, "", $3); print $1 "\t" $3 }' "$named"
    awk '{ print "@infra\t" $0 }' "$TI_TMP/inputs.infra"
  } | LC_ALL=C sort -u
}

# ti_inputs_infra <map> <helper-rows> <files> — the v2 `@infra` paths
# (BH-6406), the paths the map cannot speak for, so every fingerprint moves
# with them. The union of:
#   1. what ti_infra_core_re matches;
#   2. a tests/lib/ path, not *.md, that no map or helper row names exactly
#      (the tests/lib/ directory row is no proof of a consumer);
#   3. a catalog/ path, not *.md, with no specific map row (ti_specific: an
#      exact or directory row that is not a whole-tree root row);
#   4. any other tests/lib/ or catalog/ path, not *.md, that the TREE's own
#      catalog/ci-batch-escalate.tsv escalates (cbe_reason; the global
#      helpers). CI_BATCH_ESCALATE_TSV is never read: the fingerprint is a
#      function of the tree.
# A rules lib that cannot be sourced is every tests/lib/ and catalog/ path
# (the v1 set); an unreadable rules file is the same, because cbe_reason then
# escalates every path. This is the set a batch select (TI_BATCH_SELECT=1)
# would call `unmapped path` or that its rules escalate, so a path moves a
# suite's fingerprint exactly when that select would run the suite.
ti_inputs_infra() {
  local map="$1" helpers="$2" files="$3" cand="$TI_TMP/infra.cand" p
  { grep -E "$ti_infra_core_re" "$files" || :; } > "$TI_TMP/infra.core"
  if ! ( . "$ROOT/bin/lib/ci-batch-escalate.sh" && command -v cbe_reason ) > /dev/null 2>&1; then
    { cat "$TI_TMP/infra.core"; grep -E '^tests/lib/|^catalog/' "$files" || :; } | LC_ALL=C sort -u
    return 0
  fi
  awk -F'\t' -v roots="$ti_root_rows" '
    FILENAME == ARGV[1] || FILENAME == ARGV[2] {
      if ($2 == "*") next
      named[$2] = 1
      if (FILENAME == ARGV[1] && index(roots, " " $2 " ") == 0 && $2 ~ /\/$/) dirs[$2] = 1
      next
    }
    /\.md$/ { next }
    /^tests\/lib\// { print (($0 in named) ? "cand" : "infra") "\t" $0; next }
    /^catalog\// {
      spec = (($0 in named) && index(roots, " " $0 " ") == 0)
      if (!spec) for (d in dirs) if (index($0, d) == 1) { spec = 1; break }
      print (spec ? "cand" : "infra") "\t" $0
    }' "$map" "$helpers" "$files" > "$cand" || { echo "test-impact: the infra scan failed" >&2; return 2; }
  {
    cat "$TI_TMP/infra.core"
    awk -F'\t' '$1 == "infra" { print $2 }' "$cand"
    awk -F'\t' '$1 == "cand" { print $2 }' "$cand" | (
      # shellcheck source=lib/ci-batch-escalate.sh
      . "$ROOT/bin/lib/ci-batch-escalate.sh" || exit 2
      export CI_BATCH_ESCALATE_TSV="$ROOT/catalog/ci-batch-escalate.tsv"
      while IFS= read -r p; do cbe_reason "$p" > /dev/null && printf '%s\n' "$p"; done
      exit 0 ) || { echo "test-impact: the escalation rules scan failed" >&2; exit 2; }
  } | LC_ALL=C sort -u
  [ "${PIPESTATUS[0]}" = 0 ] || return 2
}

# ti_emit_full <reason> — the whole corpus, as a list or as --why rows.
ti_emit_full() {
  local all total
  all=$(ti_suites); total=$(printf '%s\n' "$all" | grep -c .)
  if [ "$WHY" = 1 ]; then printf '%s\n' "$all" | awk -v r="$1" '{ print $0 "\tfull\t" r }'
  else printf '%s\n' "$all"; fi
  printf 'impact: %d of %d suites (%s)\n' "$total" "$total" "$1" >&3
}

# ti_workflow_nontest — rc 0 when TI_WORKFLOW_BASE is set and
# bin/test-impact-workflow.sh says the workflow diff from it to HEAD touches
# non-test jobs only (its rc 1). Any other answer is rc 1: the infra answer.
ti_workflow_nontest() {
  [ -n "${TI_WORKFLOW_BASE:-}" ] && [ -f "$ROOT/bin/test-impact-workflow.sh" ] || return 1
  bash "$ROOT/bin/test-impact-workflow.sh" "$TI_WORKFLOW_BASE" HEAD --root "$ROOT" > /dev/null 2>&1
  [ $? = 1 ]
}

# ti_select <map> <changed-file> — print the suites, and the reason on fd 3.
ti_select_from() {
  local map="$1" changed="$2" reason="" full="" p
  local total; total=$(ti_suites | grep -c .)

  if [ ! -s "$changed" ]; then
    # An empty diff is not a licence to run nothing: it usually means the range
    # was wrong. The always-run set still runs, and the reason says so.
    reason="selected: the diff is empty"
  fi

  local infra_re="$ti_infra_re"
  [ "${TI_BATCH_SELECT:-}" = 1 ] && infra_re="$ti_infra_core_re"
  : > "$TI_TMP/narrow"
  # The changed list ti_why_rows reads: the diff, plus each changed helper's
  # closure in a batch (BH-6371). The reason line still counts the diff.
  local work="$TI_TMP/changed.work"
  cp "$changed" "$work" 2>/dev/null || : > "$work"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "${TI_BATCH_SELECT:-}" = 1 ] && [ "$p" = .github/workflows/harness-ci.yml ] \
       && ti_workflow_nontest && ti_specific "$map" "$p"; then
      continue
    fi
    if printf '%s\n' "$p" | grep -qE "$infra_re"; then
      full="full: infra change ($p)"; break
    fi
    # A BATCH (BH-6059): bin/lib/ and catalog/ are no longer escalated whole, so
    # a path there must be one the map actually knows. A doc never goes full; it
    # is narrowed to its specific rows in ti_why_rows.
    if [ "${TI_BATCH_SELECT:-}" = 1 ]; then
      case "$p" in
        bin/lib/*.md|catalog/*.md|tests/lib/*.md) printf '%s\n' "$p" >> "$TI_TMP/narrow"; continue ;;
        bin/lib/*|catalog/*)
          ti_specific "$map" "$p" || { full="full: unmapped path ($p)"; break; } ;;
        # BH-6371: a helper selects every suite that reaches it, directly or
        # through another helper. No suite reaches it: unmapped.
        tests/lib/*)
          ti_testlib_closure "$p" > "$TI_TMP/closure"
          ti_testlib_mapped "$map" "$TI_TMP/closure" || { full="full: unmapped path ($p)"; break; }
          cat "$TI_TMP/closure" >> "$work" ;;
      esac
    fi
    # COVERED BEFORE INERT, on purpose. docs/ is inert as a rule, but a handful
    # of docs files are read BY NAME by a suite (the verification-map index is
    # one), and those must still select it. Asking "does the map know this path"
    # first makes the inert list a fallback for what nothing reads rather than a
    # veto over what something does.
    ti_covered "$map" "$p" && continue
    ti_inert "$p" && continue
    full="full: unknown reach ($p)"; break
  done < "$changed"

  # --map-only (BH-1524): the builder gate asks what the MAP can say even when
  # CI will run everything, and the reason line keeps CI's answer in view.
  if [ -n "$full" ]; then
    if [ "$MAP_ONLY" = 1 ]; then reason="map-only: CI runs the corpus, $full"
    else ti_emit_full "$full"; return 0; fi
  fi

  LC_ALL=C sort -u -o "$work" "$work"
  ti_why_rows "$map" "$work" | LC_ALL=C sort -u > "$TI_TMP/why"
  local n; n=$(cut -f1 "$TI_TMP/why" | LC_ALL=C sort -u | grep -c .)
  # A selection of nothing is never a green run of nothing. The always-run set
  # is non-empty in this repo, so an empty answer means the map or the diff is
  # not what this code thinks it is — fall through to the corpus and say so.
  if [ "$n" -eq 0 ]; then
    ti_emit_full "full: the selection came back empty"; return 0
  fi
  if [ "$WHY" = 1 ]; then cat "$TI_TMP/why"
  else cut -f1 "$TI_TMP/why" | LC_ALL=C sort -u; fi
  printf 'impact: %d of %d suites (%s)\n' "$n" "$total" \
    "${reason:-selected: $(grep -c . <"$changed") changed path(s)}" >&3
}

# ti_map_path — the map to select against: --map if given, else a fresh build.
ti_map_path() {
  if [ -n "$MAP_OVERRIDE" ]; then
    [ -r "$MAP_OVERRIDE" ] || { echo "test-impact: no such map: $MAP_OVERRIDE" >&2; return 2; }
    printf '%s\n' "$MAP_OVERRIDE"; return 0
  fi
  ti_build_map > "$TI_TMP/map" || return 2
  [ -s "$TI_TMP/map" ] || return 2
  printf '%s\n' "$TI_TMP/map"
}

ti_changed() { # <range> -> the changed paths, one per line
  local range="$1" base head
  base="${range%%..*}"; head="${range##*..}"
  [ -n "$base" ] && [ -n "$head" ] || { echo "test-impact: select needs <base>..<head>, got '$range'" >&2; return 2; }
  git -C "$ROOT" cat-file -e "$base^{commit}" 2>/dev/null || {
    echo "test-impact: cannot resolve the base commit '$base'" >&2; return 3; }
  git -C "$ROOT" cat-file -e "$head^{commit}" 2>/dev/null || {
    echo "test-impact: cannot resolve the head commit '$head'" >&2; return 3; }
  git -C "$ROOT" diff --name-only "$base" "$head"
}

# ti_schema_alias <changed-file> — THE THREE GENERATED-PATH ALIASES (BH-6005,
# BH-4987, BH-6487), on the diff side: a changed worker/<w>/schema.d/<x>.sql
# also changes the composed worker/<w>/schema.sql, a changed
# catalog/llm-sites.d/<x>.json the composed catalog/llm-sites.json, and a
# changed catalog/context-budgets.d/<x>.json the composed
# catalog/context-budgets.json, so that path is appended once. The original
# lines stay.
ti_schema_alias() {
  awk '
    { print; have[$0] = 1 }
    /^worker\/[^\/]+\/schema\.d\/[^\/]+\.sql$/ {
      split($0, p, "/"); a = "worker/" p[2] "/schema.sql"
      if (!(a in want)) { want[a] = 1; order[++n] = a }
    }
    /^catalog\/llm-sites\.d\/[^\/]+\.json$/ {
      a = "catalog/llm-sites.json"
      if (!(a in want)) { want[a] = 1; order[++n] = a }
    }
    /^catalog\/context-budgets\.d\/[^\/]+\.json$/ {
      a = "catalog/context-budgets.json"
      if (!(a in want)) { want[a] = 1; order[++n] = a }
    }
    END { for (i = 1; i <= n; i++) if (!(order[i] in have)) print order[i] }
  ' "$1" > "$1.alias" && mv "$1.alias" "$1"
}

# ── orphans ─────────────────────────────────────────────────────────────────
# A script no suite reaches is not a saving, it is a hole: the impact lane will
# correctly run nothing for a diff that touches it, which is only right if
# nothing tested it before either. So the map's own by-product is the list, and
# tests/test-impact-test.sh ratchets it against a committed file.
#
# ONLY EXACT ROWS COUNT. A whole-tree row (`*`) and a directory row (`bin/`,
# which 59 suites carry because they scan or copy the tree) would make every
# script look covered and the list would be permanently empty — a ratchet that
# can never catch anything is worse than none, because it reads like a guard.
# The question worth asking is "does some suite exercise this script BY NAME",
# and `bin/checks-run.sh --tree .` reading a file is not the same as a suite
# that knows what the file does.
#
# AND "NAMED" MEANS NAMED ON A LINE THAT IS NOT A COMMENT (BH-1253). The map is
# a static over-approximation on purpose, so a `# see $DIR/bin/x.sh for the real
# thing` counts as a citation there and the worst it costs is one extra suite on
# a diff — the documented safe direction. For the RATCHET it is the opposite
# direction: a script whose only mention in the whole corpus is a sentence in a
# comment has no test, and counting it hid 18 holes, `bin/board-invariants.sh`
# among them. So the map built FOR the orphan list skips `#`-led lines
# (TI_ORPHAN_STRICT below) and the map every other command builds does not.
# A TRAILING comment after real code still counts: only a line whose first
# non-blank character is `#` is skipped.
ti_orphan_subjects() {
  ( cd "$ROOT" && ls bin/*.sh bin/lib/*.sh bin/lib/*/*.sh bin/remediations/*.sh \
       worker/*.js worker/jobs/*.js console-ui/src/*.js console-ui/src/*/*.js 2>/dev/null ) |
    LC_ALL=C sort -u
}

ti_orphans() {
  # The strict reading, scoped to this call. bash's dynamic scoping carries it
  # into ti_build_map and no further, so `map`, `select`, `ci-select` and
  # `audit` are untouched — and ti_orphans_at re-runs THIS script's `orphans`
  # for the base tree, so both sides of the ratchet are scored by one
  # definition. `--map` still wins: a caller that hands over a pre-built map
  # gets that map's rows, exactly as before.
  local TI_ORPHAN_STRICT=1
  local map; map=$(ti_map_path) || return 2
  awk -F'\t' -v mapfile="$map" '
    FILENAME == mapfile { if ($2 != "*" && $2 !~ /\/$/) seen[$2] = 1; next }
    { if (!($0 in seen)) print }
  ' "$map" <(ti_orphan_subjects)
}

# ── THE RATCHET IS A SET DIFF AGAINST THE MERGE-BASE (BH-1268) ─────────────
# BH-1203 committed the orphan list and compared it exactly: a NEW orphan was
# refused, and a FIXED one had to be deleted from the file in the same PR. The
# second half is what made it a shared mutable cell — every PR that added a
# suite naming a previously-orphan script carried a regenerated list, so an
# unrelated PR was re-reddened by a neighbour's merge (#842, #1161, #1029,
# #1212 and #1191 on 2026-09-21 alone).
#
# WHAT REPLACES IT IS THE SAME QUESTION, ASKED OF TWO TREES. The old case G's
# NEWLY was "live minus the committed list"; this is "live minus THE BASE'S
# live" — the base being this branch's merge-base with main. FIXED still needs
# no commit, and a neighbour's merge cannot re-red anybody, because every branch
# is compared against its own base rather than against a file main moves.
#
# WHY NOT A COMMITTED COUNT, which is what the ticket first proposed. A floor
# only refuses while live == floor. The moment one orphan is fixed and nobody
# lowers the number — and nothing requires it, a drop being no regression —
# the ratchet is blind by the width of the slack, and the next script added with
# no suite passes green "at the floor". That was not hypothetical: at review
# time main stood at 102 orphans against a proposed floor of 103, so the floor
# would have shipped one script blind. The same slack swallows a SWAP (fix one,
# add one). A base diff has no slack to drift into and no number to re-derive.
#
# THE COST is one extra map build over the base tree: `git archive` the base,
# run THIS script against the extracted tree, `comm` the two lists. ~5 s.
# The CURRENT script reads the OLD tree on purpose — one spelling of what an
# orphan is, so a change to the definition cannot be scored against itself.
TI_ORPHAN_LIST_REL=catalog/test-impact-orphans.txt

# ti_orphans_base_ref — the commit this branch's orphans are judged against.
#   TI_BASE                  what CI already exports (pull_request.base.sha),
#                            plumbed into four jobs of harness-ci.yml already
#   merge-base with main     the local answer, and the same one on a push
# Nothing else. A base that cannot be resolved is rc 1 from here and rc 2 from
# the caller: "there is no new orphan" is a claim, and a run that cannot reach
# a base has not made it. Printing a green for that is the failure this file
# spends most of its comments avoiding.
ti_orphans_base_ref() {
  local b
  if [ -n "${TI_BASE:-}" ]; then
    if git -C "$ROOT" cat-file -e "$TI_BASE^{commit}" 2>/dev/null; then
      printf '%s\n' "$TI_BASE"; return 0
    fi
    echo "test-impact: TI_BASE='$TI_BASE' does not resolve to a commit in $ROOT" >&2
    return 1
  fi
  for b in origin/main main; do
    git -C "$ROOT" cat-file -e "$b^{commit}" 2>/dev/null || continue
    git -C "$ROOT" merge-base HEAD "$b" 2>/dev/null && return 0
  done
  echo "test-impact: no base to compare against — set TI_BASE, or fetch origin/main" >&2
  return 1
}

# ti_orphans_at <commit> — the orphan list of that commit's tree, computed by
# THIS script in a subprocess of its own. A subprocess rather than a rebind of
# $ROOT because the map build owns files under $TI_TMP (the index, the map) and
# two runs sharing them would score one tree with the other's index.
ti_orphans_at() {
  local ref="$1" tree="$TI_TMP/basetree"
  rm -rf "$tree"; mkdir -p "$tree" || return 1
  git -C "$ROOT" archive "$ref" 2>/dev/null | tar -x -C "$tree" 2>/dev/null || {
    echo "test-impact: could not extract the tree at $ref" >&2; return 1; }
  [ -d "$tree/bin" ] && [ -d "$tree/tests" ] || {
    echo "test-impact: the tree at $ref has no bin/ and tests/ — not this repo" >&2; return 1; }
  bash "$TI_SELF" --root "$tree" orphans || return 1
}

# ti_orphans_check — rc 0 when this diff adds no orphan, rc 1 when it adds one
# or has the derived list committed, rc 2 when the question could not be asked.
ti_orphans_check() {
  local base bad=0 new fixed
  # 1. A TRACKED LIST, full stop — the gate BH-1175 taught. The .gitignore is
  #    the fence; this is the gate. A PR that deletes the ignore line and
  #    `git add -f`s the list puts the contested cell back with every reader
  #    still assuming otherwise, and a gate whose subject can delete the gate is
  #    not a gate. The file is allowed to EXIST — every consumer writes it.
  if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "$(git -C "$ROOT" ls-files -- "$TI_ORPHAN_LIST_REL" 2>/dev/null)" ]; then
      echo "test-impact: $TI_ORPHAN_LIST_REL is TRACKED in git. It is DERIVED and must not be committed (BH-1268):" >&2
      echo "test-impact:   git rm --cached $TI_ORPHAN_LIST_REL   — nothing about the orphan set is committed any more" >&2
      if ! git -C "$ROOT" check-ignore -q --no-index -- "$TI_ORPHAN_LIST_REL" 2>/dev/null; then
        echo "test-impact:   and .gitignore no longer covers it — restore that line too, or the next build commits it again" >&2
      fi
      bad=1
    fi
  else
    echo "test-impact: $ROOT is not a git checkout — there is no base to compare against" >&2
    return 2
  fi

  base=$(ti_orphans_base_ref) || return 2
  # The lists go to files, not through a pipe: `ti_orphans | sort` would turn
  # "the map could not be built" into an empty list, which reads as a tree with
  # no holes in it — the one answer this check must never invent.
  ti_orphans_at "$base" | LC_ALL=C sort > "$TI_TMP/orph.base" || {
    echo "test-impact: the orphan list of the base ($base) could not be computed" >&2; return 2; }
  ti_orphans | LC_ALL=C sort > "$TI_TMP/orph.head" || {
    echo "test-impact: the orphan list could not be computed (the map would not build)" >&2; return 2; }

  new=$(comm -13 "$TI_TMP/orph.base" "$TI_TMP/orph.head")
  fixed=$(comm -23 "$TI_TMP/orph.base" "$TI_TMP/orph.head")

  if [ -n "$new" ]; then
    echo "test-impact: this diff adds $(printf '%s\n' "$new" | grep -c .) orphan script(s) — no suite names them:" >&2
    printf '%s\n' "$new" | sed 's/^/test-impact:   /' >&2
    echo "test-impact: a script no suite names BY NAME is a hole: the impact lane correctly selects no" >&2
    echo "test-impact: suite for a diff that touches it, which is only right if nothing tested it before." >&2
    echo "test-impact: add a suite whose TEXT names the script (\"\$DIR/bin/<name>.sh\"), or say in the PR" >&2
    echo "test-impact: body why this one has no suite. Base: $base" >&2
    bad=1
  fi

  [ "$bad" = 0 ] || return 1
  printf 'test-impact: no new orphans against %.12s (%d live, %d fixed by this diff)\n' \
    "$base" "$(grep -c . <"$TI_TMP/orph.head")" "$(printf '%s\n' "$fixed" | grep -c .)"
  return 0
}

# ── the corpus-wide coverage audit (BH-1203 review B1) ──────────────────────
# THE CASE THAT WOULD HAVE CAUGHT B1 IN ONE PASS. Case B guards ONE library with
# a hand-listed divergence, and eight suites were being dropped beside it. This
# asks the question of the whole corpus instead:
#
#   for every suite, on every line that names the CHECKOUT, every token that
#   resolves to a real file in the tree must be a row of that suite.
#
# It is written to be INDEPENDENT of the map's own extractor and deliberately
# cruder: it does not care about TI_PREFIX, it does not care whether the
# individual token is rooted, and it strips any `$VAR/` or `{VAR}/` prefix from
# a token before testing it. A line that mentions the checkout and names a real
# file is treated as a dependency, full stop. The two agree only if the map is
# doing its job; where they disagree, the map is wrong, because the safe
# direction is always the extra row.
#
# THE RESIDUAL BLIND SPOT, stated rather than hidden: a line that reaches the
# checkout through a SIXTH spelling neither the normaliser nor this audit
# recognises is invisible to both. That is why the normaliser has one list of
# forms and not five scattered branches — a new form is one gsub, and this audit
# starts checking its lines the moment it is added.
ti_audit() {
  # Same rule as ti_build_map: the suite list is an argv, so it is built — and
  # refused when empty — BEFORE any awk runs, or an empty glob turns the audit
  # into a read of stdin (BH-1253).
  local _s _files=()
  while IFS= read -r _s; do [ -n "$_s" ] && _files+=("$_s"); done < <(ti_suites)
  [ "${#_files[@]}" -gt 0 ] || { echo "test-impact: no suites under tests/ in $ROOT" >&2; return 2; }

  local map; map=$(ti_map_path) || return 2
  # The index is built by ti_build_map, which --map skips — so the audit builds
  # its own when it was handed a map to check rather than one it made.
  [ -s "$TI_TMP/index" ] || ti_files > "$TI_TMP/index"
  [ -s "$TI_TMP/index" ] || { echo "test-impact: $ROOT holds no files" >&2; return 2; }
  ti_rootvars "${_files[@]}" > "$TI_TMP/rootvars"
  ( cd "$ROOT" && awk -v idxfile="$TI_TMP/index" -v rvfile="$TI_TMP/rootvars" \
      -v mapfile="$map" -v ROOTVAR_="$TI_ROOTVAR" \
      "$TI_AWK_INDEX$TI_AWK_NORM"'
      FILENAME == idxfile { FILE_[$0] = 1; adddirs($0); next }
      FILENAME == rvfile  { if ($2 == "@PYARGV@") PY_[$1] = 1
                            # The ternary is mawk-fatal here too — see the note
                            # at the same spot in ti_build_map.
                            else if ($1 in RV_) RV_[$1] = RV_[$1] "|" $2
                            else RV_[$1] = $2
                            next }
      FILENAME == mapfile { FS = "\t"; if ($2 == "*") whole[$1] = 1
                            else if ($2 ~ /\/$/) { np[$1]++; pfx[$1, np[$1]] = $2 }
                            else row[$1 SUBSEP $2] = 1
                            FS = " "; next }
      {
        line = ti_norm($0, FILENAME)
        if (index(line, "@ROOT@") == 0) next
        if (FILENAME in whole) next
        n = split(line, w, /[^A-Za-z0-9._\/@$+{}-]+/)
        for (i = 1; i <= n; i++) {
          t = w[i]
          # A token carried by SOME OTHER variable is a scratch path, not a
          # checkout one: the root variables were already turned into @ROOT@ by
          # ti_norm, so anything still wearing a `$VAR/` or `{VAR}/` prefix here
          # is by definition not the checkout. Without this, a line like
          # `cp "$DIR/bin/a.sh" "$T/bin/billing-mode.sh"` demands a row for the
          # stub the suite WRITES, and the audit spends its credibility on
          # findings that are not dependencies.
          if (sub(/^@ROOT@\//, "", t)) { }
          else if (t ~ /^[$]?\{?[A-Za-z_][A-Za-z0-9_]*\}?\//) continue
          while (sub(/^\.\.?\//, "", t)) { }
          if (t == "" || !isfile(t)) continue
          if ((FILENAME SUBSEP t) in row) continue
          covered = 0
          for (j = 1; j <= np[FILENAME]; j++) if (index(t, pfx[FILENAME, j]) == 1) { covered = 1; break }
          if (!covered) print FILENAME "\t" t
        }
      }
    ' "$TI_TMP/index" "$TI_TMP/rootvars" "$map" "${_files[@]}" ) |
    LC_ALL=C sort -u
}

# ── the CI decision ─────────────────────────────────────────────────────────
# Full-versus-selected lives HERE and not in YAML, so it is testable. The
# workflow passes what it knows and prints what comes back.
#
#   TI_EVENT       push | pull_request      (push to main is always the corpus)
#   TI_BASE        the PR's base sha
#   TI_HEAD        the head to diff to      (default HEAD)
#   TI_PR_TITLE    a title starting "merge train" is a train: full corpus
#   TI_PR_LABELS   newline- or comma-separated; `full` forces the corpus
#
# Every unknown falls to FULL. The expensive failure is one slow CI run; the
# silent one is a regression that shipped because its suite was not selected.
ti_ci_select() {
  local ev="${TI_EVENT:-}" base="${TI_BASE:-}" head="${TI_HEAD:-HEAD}"
  local title="${TI_PR_TITLE:-}" labels="${TI_PR_LABELS:-}"
  local all total reason=""
  all=$(ti_suites); total=$(printf '%s\n' "$all" | grep -c .)

  case "$ev" in
    pull_request) ;;
    push) reason="full: push to $(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)" ;;
    *)    reason="full: event '$ev' is not a pull request" ;;
  esac
  # WHAT A TRAIN LOOKS LIKE IS bin/lib/train-shape.sh's ANSWER (BH-1428). Both
  # spellings live there — BH-1203 specified "merge train"; the PR
  # bin/batch-resolve.sh actually opens is titled
  # `batch(<project>): land N approved siblings as one train` — and so does the
  # merge LADDER's copy of the question, which learned only one pair and
  # squash-merged a batch train. A train carries several tickets' changes at
  # once, so it is the ONE pull request where a partial corpus is least
  # defensible. A missing lib selects the FULL corpus, this script's own
  # fail-open direction, rather than a second copy of the regex.
  if [ -z "$reason" ]; then
    if ! command -v train_is_train >/dev/null 2>&1; then
      # NEXT TO THIS SCRIPT, never under $ROOT: --repo points ROOT at another
      # checkout, which owes this lane no lib of ours.
      . "$SELF_DIR/lib/train-shape.sh" 2>/dev/null || reason="full: the train recogniser could not be read"
    fi
    [ -z "$reason" ] && train_is_train "$title" "${TI_PR_HEAD_REF:-}" && reason="full: merge train"
  fi
  [ -z "$reason" ] && printf '%s\n' "$labels" | tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -qxF full &&
    reason="full: the 'full' label"
  [ -z "$reason" ] && [ -z "$base" ] && reason="full: no base sha to diff against"

  if [ -n "$reason" ]; then
    printf '%s\n' "$all"
    printf 'impact: %d of %d suites (%s)\n' "$total" "$total" "$reason" >&3
    return 0
  fi
  ti_run_select "$base..$head"
}

# ti_run_select <range> — the shared body of `select` and `ci-select`. Every
# failure below prints the corpus: a selection that could not be computed is the
# one case where running everything is the cheap answer.
ti_run_select() {
  local changed="$TI_TMP/changed" map
  if [ -n "$CHANGED_FILE" ]; then
    # --changed: the list IS the diff. Unreadable is the corpus, never nothing.
    [ -r "$CHANGED_FILE" ] && cp "$CHANGED_FILE" "$changed" || {
      ti_emit_full "full: cannot read the --changed list $CHANGED_FILE"; return 0; }
  elif ti_changed "$1" > "$changed"; then
    # The base the named kind reads deleted and renamed functions from.
    TI_NAMED_BASE="${1%%..*}"
  else
    ti_emit_full "full: cannot diff $1"; return 0
  fi
  # Both paths: the merge queue's --changed list never runs ti_changed.
  ti_schema_alias "$changed"
  if ! map=$(ti_map_path); then
    ti_emit_full "full: the map could not be built"; return 0
  fi
  ti_select_from "$map" "$changed"
}

# ── dispatch ────────────────────────────────────────────────────────────────
ti_emit() { # run a producer with fd 3 = the reason channel, fd 1 = the list
  if [ -n "$OUT" ]; then
    "$@" 3>&2 > "$OUT" || return $?
  else
    "$@" 3>&2 || return $?
  fi
}

case "$CMD" in
  map)
    if [ -n "$OUT" ]; then ti_build_map > "$OUT"; else ti_build_map; fi ;;
  select)
    [ "${#ARGS[@]}" -ge 1 ] || [ -n "$CHANGED_FILE" ] || {
      echo "test-impact: select needs <base>..<head> (or --changed <file>)" >&2; exit 2; }
    ti_emit ti_run_select "${ARGS[0]:-}" ;;
  ci-select)
    ti_emit ti_ci_select ;;
  orphans)
    if [ "$CHECK" = 1 ]; then ti_orphans_check
    elif [ -n "$OUT" ]; then ti_orphans > "$OUT"
    else ti_orphans; fi ;;
  audit)
    if [ -n "$OUT" ]; then ti_audit > "$OUT"; else ti_audit; fi ;;
  always)
    if [ -n "$OUT" ]; then ti_always > "$OUT"; else ti_always; fi ;;
  always-why)
    if [ -n "$OUT" ]; then ti_always_why > "$OUT"; else ti_always_why; fi ;;
  inputs)
    if [ -n "$OUT" ]; then ti_inputs > "$OUT"; else ti_inputs; fi ;;
  ""|help)
    sed -n '2,48p' "$0"; exit 0 ;;
  *)
    echo "test-impact: unknown command '$CMD' (map, select, ci-select, orphans, audit, always, always-why, inputs)" >&2; exit 2 ;;
esac
