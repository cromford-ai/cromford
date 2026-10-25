#!/bin/bash
# tests/verification-map-test.sh — the primer PLAN already promises to read must
# be composed only from files that exist, and must say ABSENT when they do not.
#
# WHY THESE ASSERTIONS. `run-build.sh` and `run-preplan.sh` have told every
# planner since July: "if state/<project>-context.md exists, read it FIRST — it
# is the project primer". Nothing wrote it. Wave B writes it, and the danger of
# writing it is the same one bin/triage-map.sh names in its own header: a
# hand-maintained map goes stale and then LIES, which is worse than no map. So
# the tests pin the two properties that make it safe rather than merely present:
#
#   1. every section is copied from a real file and CITES it (assertion 11 walks
#      the rendered output and refuses any section header that neither carries a
#      source: citation nor opens with ABSENT),
#   2. a missing source renders ABSENT — never silence, and never a guess. A
#      planner that cannot tell "no map here" from "nobody looked" goes hunting,
#      which is the cost this whole wave removes.
#
# The run-build wiring is tested by extracting the REAL CC() dispatcher and the
# REAL orientation block out of run-build.sh and executing them, not by retyping
# them — a test of a copy proves the copy (tests/codegraph-injection-test.sh).
# Run from anywhere: tests/verification-map-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
VM="$DIR/bin/verification-map.sh"
RB="$RB_ALL"
FIX="$DIR/catalog/fixtures/verification-map"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$VM" ] && ok || bad "bin/verification-map.sh is missing or not executable"

# A harness root the render can write its state file into.
H="$T/harness"; mkdir -p "$H/state"
render() { HARNESS="$H" "$VM" render "$1" --repo "$2" 2>&1; }
orient() { HARNESS="$H" "$VM" orient "$1" --repo "$2" 2>&1; }

# Fixture trees are copied, never rendered against in place: the staleness arm
# rewrites mtimes, and a test that mutated the committed fixtures would pass
# once and then poison every later run.
cp -R "$FIX/full" "$T/full"
cp -R "$FIX/absent" "$T/absent"

# ---------- 1. a repo WITH a map: the primer is the map, cited ---------------
render demo-os "$T/full" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "render on a mapped repo must exit 0 (got $RC)"
OUT="$H/state/demo-os-context.md"
[ -s "$OUT" ] && ok || bad "render must write \$HARNESS/state/<project>-context.md (the dangling PLAN read contract)"
P=$(cat "$OUT" 2>/dev/null)

grep -q 'Verification map — demo-os' <<<"$P" \
  && ok || bad "the primer must carry the repo's map index verbatim"
grep -q 'docs/verification-map/README.md' <<<"$P" \
  && ok || bad "the index section must cite the file it came from"
grep -q 'billing.md' <<<"$P" && grep -q 'client-intake.md' <<<"$P" \
  && ok || bad "every per-feature entry must be listed"
# README is the index, not a feature. Listing it as one is a small lie that
# makes the entry count wrong everywhere it is quoted.
grep -qE '^[[:space:]]+README\.md$' <<<"$P" \
  && bad "README.md must not be listed as a feature entry" || ok
grep -qi 'poll an observable end-state' <<<"$P" \
  && ok || bad "the driving conventions must be carried into the primer"
grep -q 'npm run test:projection' <<<"$P" \
  && ok || bad "the repo CLAUDE.md's Verification Contract must be carried into the primer"
grep -qE 'CLAUDE\.md:[0-9]+' <<<"$P" \
  && ok || bad "the contract section must cite CLAUDE.md with the line it was taken from"
grep -q 'AGENT_ARCHITECTURE.md' <<<"$P" \
  && ok || bad "an AGENT_ARCHITECTURE.md present in the repo must be pointed at (Wave C writes these)"
grep -q 'ABSENT' <<<"$P" \
  && bad "a fully-sourced repo must render no ABSENT lines (got: $(grep -m1 ABSENT <<<"$P"))" || ok

# ---------- 11. EVERY section is either cited or explicitly ABSENT ----------
# The property that makes this file safe to inject. Walk the rendered sections:
# a header without a `source:` citation must be followed immediately by ABSENT.
# Anything else is uncited prose about the app — the failure mode triage-map.sh
# calls out by name, and the one no amount of careful writing prevents.
UNCITED=$(awk '
  /^--- / && !/^--- END/ { hdr=$0; cited=(index($0,"source:")>0); getline nxt;
    if (!cited && nxt !~ /^ABSENT:/ && nxt !~ /^COULD NOT READ/) print hdr; next }
' "$OUT")
[ -z "$UNCITED" ] && ok || bad "uncited section(s) in the primer: $UNCITED"

# ---------- 2. a repo WITHOUT a map: honest ABSENT, not silence -------------
render bare-os "$T/absent" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "render on an unmapped repo must still exit 0 and write a primer (got $RC)"
Q=$(cat "$H/state/bare-os-context.md" 2>/dev/null)
grep -q 'ABSENT:' <<<"$Q" \
  && ok || bad "a missing map must render an explicit ABSENT line"
grep -q 'docs/verification-map' <<<"$Q" \
  && ok || bad "the ABSENT line must name the path that is missing, so nobody hunts for it"
grep -q 'VERIFICATION MAP (source:' <<<"$Q" \
  && bad "an unmapped repo must never render a sourced map section" || ok
# a CLAUDE.md with no contract block is its own ABSENT — not borrowed from the
# other fixture, and not invented
grep -qi 'ABSENT.*Verification' <<<"$Q" \
  && ok || bad "a CLAUDE.md with no Verification Contract block must render ABSENT for that section"
grep -q 'npm run test' <<<"$Q" \
  && bad "the primer must not carry a contract this repo does not have" || ok
grep -q 'AGENT_ARCHITECTURE' <<<"$Q" \
  && ok || bad "a missing AGENT_ARCHITECTURE.md must be named as absent, not omitted silently"

# ---------- 3. the BOLD contract shape (what project-2 really uses) -----
cp "$FIX/claude-md-bold.md" "$T/absent/CLAUDE.md"
render bare-os "$T/absent" >/dev/null
B=$(cat "$H/state/bare-os-context.md" 2>/dev/null)
grep -q 'npm run test:projection' <<<"$B" \
  && ok || bad "a **Verification** bold-section contract must be found (the real project-2 shape)"
grep -q 'Product board' <<<"$B" \
  && bad "the extraction must stop at the next section, not swallow the rest of CLAUDE.md" || ok

# ---------- 4. map present, conventions section missing ---------------------
# Partial adoption is the common case mid-backfill. The map still renders; the
# conventions do not get invented from the harness's wishes.
cp -R "$T/full" "$T/noconv"
python3 - "$T/noconv/docs/verification-map/README.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, 'w').write(s.split('## Driving conventions')[0])
PY
render noconv-os "$T/noconv" >/dev/null
N=$(cat "$H/state/noconv-os-context.md" 2>/dev/null)
grep -q 'Verification map — demo-os' <<<"$N" \
  && ok || bad "a map with no conventions section must still render its index"
grep -qi 'ABSENT.*conventions\|CONVENTIONS.*ABSENT' <<<"$N" \
  && ok || bad "missing driving conventions must render ABSENT, not be filled in from the harness template"

# ---------- 5. render's rc contract: nonzero = no primer --------------------
# Callers treat nonzero as "no map" and say so out loud (the triage-map
# contract). It must therefore mean exactly one thing: nothing was written.
OUTM=$(HARNESS="$H" "$VM" render ghost-os --repo "$T/does-not-exist" 2>&1); RC=$?
[ "$RC" != 0 ] && ok || bad "render against a missing checkout must exit nonzero"
[ ! -f "$H/state/ghost-os-context.md" ] \
  && ok || bad "a nonzero render must leave no primer behind — a caller that saw rc!=0 will say 'no map', and a file on disk would contradict it"
grep -qi 'no checkout\|does-not-exist' <<<"$OUTM" \
  && ok || bad "the failure must name its reason (got: $OUTM)"

# ---------- 6. orient: one deterministic availability line, three outcomes --
# A `cp -R` leaves arbitrary mtime ordering, so the fresh case is stated
# explicitly rather than assumed — which is also the honest reading of what an
# mtime comparison can and cannot tell you.
touch -t 202601010000 "$T/full/src/app/billing/page.tsx" "$T/full/src/app/layout.tsx"
touch -t 202606010000 "$T/full/docs/verification-map"/*.md
O=$(orient demo-os "$T/full"); RC=$?
[ "$RC" = 0 ] && ok || bad "orient must always exit 0 — it is a prompt line, never a gate (got $RC)"
[ "$(head -1 <<<"$O" | grep -c '^VERIFICATION MAP AVAILABLE (')" = 1 ] \
  && ok || bad "a mapped, fresh repo must render AVAILABLE on the FIRST line (got: $(head -1 <<<"$O"))"
grep -q '2 ' <<<"$(head -1 <<<"$O")" \
  && ok || bad "the AVAILABLE line must report the entry count (2 in this fixture): $(head -1 <<<"$O")"
grep -q 'docs/verification-map' <<<"$O" \
  && ok || bad "the AVAILABLE line must name where the map is"

O=$(orient bare-os "$T/absent")
grep -q '^VERIFICATION MAP NOT AVAILABLE (' <<<"$(head -1 <<<"$O")" \
  && ok || bad "an unmapped repo must render NOT AVAILABLE (got: $(head -1 <<<"$O"))"
grep -qE 'NOT AVAILABLE \(.+\)' <<<"$O" \
  && ok || bad "NOT AVAILABLE must carry a reason"

# staleness is an mtime fact, and it must move in BOTH directions or it is not
# measuring anything: an index older than a route file is stale; touch the index
# and the same tree is fresh again.
touch -t 202601010000 "$T/full/docs/verification-map"/*.md
touch -t 202606010000 "$T/full/src/app/billing/page.tsx"
grep -q '^VERIFICATION MAP STALE (' <<<"$(orient demo-os "$T/full" | head -1)" \
  && ok || bad "an index older than a route file must render STALE (got: $(orient demo-os "$T/full" | head -1))"
grep -qi 'verify' <<<"$(orient demo-os "$T/full")" \
  && ok || bad "STALE must tell the reader what to do about it (verify before trusting an entry)"
touch -t 202607010000 "$T/full/docs/verification-map/billing.md"
grep -q '^VERIFICATION MAP AVAILABLE (' <<<"$(orient demo-os "$T/full" | head -1)" \
  && ok || bad "touching the map must clear STALE — otherwise the check is not reading mtimes at all"

# ---------- 6b. the signal a REAL build sees: last-commit time, not mtime ----
# This is the production path and it is the one that can silently lie. A build
# runs in a `git worktree add` checkout where every file is written at checkout
# time, so mtime ordering between the map and a route file is arbitrary — an
# mtime-only check fires STALE at random there, and a warning that fires at
# random is one the reader stops reading. The fixture makes the two signals
# DISAGREE on purpose: git history says the route moved after the map, the
# mtimes say the opposite, and the verdict must follow history.
G="$T/git"; mkdir -p "$G"; cp -R "$FIX/full/." "$G/"
git -C "$G" init -q . >/dev/null 2>&1
git -C "$G" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z \
  git -C "$G" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
printf '// a route change with no map change\n' >> "$G/src/app/billing/page.tsx"
git -C "$G" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE=2026-06-01T00:00:00Z GIT_COMMITTER_DATE=2026-06-01T00:00:00Z \
  git -C "$G" -c user.email=t@t -c user.name=t commit -qm "route change" >/dev/null 2>&1
touch -t 202608010000 "$G/docs/verification-map"/*.md   # mtimes say "map is newest"
O=$(orient demo-os "$G")
grep -q '^VERIFICATION MAP STALE (' <<<"$(head -1 <<<"$O")" \
  && ok || bad "in a git checkout the verdict must follow commit history, not mtimes (got: $(head -1 <<<"$O"))"
grep -q 'src/app/billing/page.tsx' <<<"$O" \
  && ok || bad "STALE must name the route file whose commit outran the map"
printf '\n- a new selector\n' >> "$G/docs/verification-map/billing.md"
git -C "$G" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE=2026-07-01T00:00:00Z GIT_COMMITTER_DATE=2026-07-01T00:00:00Z \
  git -C "$G" -c user.email=t@t -c user.name=t commit -qm "map catch-up" >/dev/null 2>&1
grep -q '^VERIFICATION MAP AVAILABLE (' <<<"$(orient demo-os "$G" | head -1)" \
  && ok || bad "committing the map catch-up must clear STALE"

# ---------- 6c. the verdict must not depend on the CALLER'S cwd -------------
# Live bug found in review. `for g in $ROUTE_GLOBS` word-splits AND GLOBS in
# whatever directory the caller happens to be in, and run-build.sh cd's into the
# checkout before this runs — so in production the git pathspec silently became
# "the top-level route files that exist right now" instead of the route dirs.
# A commit that DELETES a route file then matches no pathspec and the map reads
# AVAILABLE from inside the repo while reading STALE from outside: the same
# repo, two answers, and the wrong one is the one production gets.
D="$T/gitdel"; mkdir -p "$D"; cp -R "$FIX/full/." "$D/"
git -C "$D" init -q . >/dev/null 2>&1
git -C "$D" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z \
  git -C "$D" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
git -C "$D" rm -q src/app/layout.tsx >/dev/null 2>&1
GIT_AUTHOR_DATE=2026-06-01T00:00:00Z GIT_COMMITTER_DATE=2026-06-01T00:00:00Z \
  git -C "$D" -c user.email=t@t -c user.name=t commit -qm "delete a route" >/dev/null 2>&1
orient_from() { ( cd "$1" && HARNESS="$H" "$VM" orient "$2" --repo "$3" 2>&1 ); }
IN=$(orient_from "$D" delproj "$D" | head -1)
OUTSIDE=$(orient_from "$T" delproj "$D" | head -1)
grep -q '^VERIFICATION MAP STALE (' <<<"$OUTSIDE" \
  && ok || bad "a commit deleting a route with no map change must be STALE (from outside: $OUTSIDE)"
grep -q '^VERIFICATION MAP STALE (' <<<"$IN" \
  && ok || bad "same repo, called from INSIDE it, must give the same verdict — this is the cwd-glob bug (got: $IN)"
[ "$IN" = "$OUTSIDE" ] \
  && ok || bad "the verdict must not depend on the caller's cwd (inside: $IN / outside: $OUTSIDE)"

# ---------- 6d. a shallow clone cannot be judged by commit time -------------
# depth-1 history gives every file the same single commit, so the commit-time
# comparison always answers "fresh" — an unfalsifiable AVAILABLE. It must fall
# back to mtimes and SAY which signal it used.
if git clone --depth 1 -q "file://$T/git" "$T/shallow" >/dev/null 2>&1; then
  touch -t 202601010000 "$T/shallow/docs/verification-map"/*.md
  touch -t 202606010000 "$T/shallow/src/app/billing/page.tsx"
  SH=$(orient demo-os "$T/shallow")
  grep -q '^VERIFICATION MAP STALE (' <<<"$(head -1 <<<"$SH")" \
    && ok || bad "a shallow clone must degrade to the mtime signal, not report an unfalsifiable AVAILABLE (got: $(head -1 <<<"$SH"))"
  grep -qi 'mtime' <<<"$SH" \
    && ok || bad "the line must name the signal it actually used when history is truncated"
else
  echo "NOTE: could not make a shallow clone here — the shallow assertions did not run"
fi

# ---------- 6e. a `##` contract keeps its `###` subsections ------------------
# The commands live in the subsections. Breaking at any heading level drops them
# with no marker at all, under a banner that says do NOT re-derive this.
cp "$FIX/claude-md-subsections.md" "$T/absent/CLAUDE.md"
render bare-os "$T/absent" >/dev/null
S=$(cat "$H/state/bare-os-context.md" 2>/dev/null)
grep -q 'npm run test:deep' <<<"$S" \
  && ok || bad "a ## contract's ### subsections carry the commands — they must not be amputated"
grep -q 'Suites at regression risk' <<<"$S" \
  && ok || bad "every subsection of the matched section belongs to it"
grep -q 'Nothing below this line belongs to the contract' <<<"$S" \
  && bad "the extraction must still stop at the next same-level heading" || ok

# ---------- 6f. a tool failure is not a statement about the repo ------------
# Found in review: an unreadable CLAUDE.md rendered "ABSENT: this repo does not
# state its test contract" — a claim about the repo that the tool never
# established. Three outcomes here too: sourced / absent / could-not-read.
# A directory named CLAUDE.md is the root-proof version of "unreadable".
rm -f "$T/absent/CLAUDE.md"; mkdir -p "$T/absent/CLAUDE.md"
render bare-os "$T/absent" >/dev/null
U=$(cat "$H/state/bare-os-context.md" 2>/dev/null)
grep -q "COULD NOT READ $T/absent/CLAUDE.md" <<<"$U" \
  && ok || bad "an unreadable CLAUDE.md must render COULD NOT READ, not an absence claim"
grep -qiE 'ABSENT.*(test contract|no Verification section)' <<<"$U" \
  && bad "a tool failure must never be reported as 'this repo does not state its contract'" || ok
# ...and the opposite error is just as wrong: a file that is genuinely NOT THERE
# is an absence, not a tool failure. (This repo has no map at all, so its
# README is missing rather than unreadable.)
grep -q 'COULD NOT READ.*README.md' <<<"$U" \
  && bad "a missing file must render ABSENT — only an unreadable one is a tool failure" || ok
grep -q 'ABSENT: no driving-conventions section' <<<"$U" \
  && ok || bad "a missing README must still render as an absence"
grep -q 'claude-md-verification=unknown' <<<"$U" \
  && ok || bad "the header's source flags must carry the unknown state too"
rm -rf "$T/absent/CLAUDE.md"

# ---------- 7. run-build wiring: the REAL CC(), executed --------------------
python3 - "$RB" "$T/cc.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("CC() { # CC <stage>")
end = src.index("\n}\n", start) + len("\n}\n")
open(sys.argv[2], "w").write(src[start:end])
PY
[ -s "$T/cc.sh" ] && ok || bad "could not extract CC() from run-build.sh"
mkdir -p "$T/h/bin" "$T/out"
cat > "$T/h/bin/agent-call.sh" <<'STUB'
#!/bin/bash
printf '%s' "$6" > "$OUTDIR/$1.prompt"
STUB
chmod +x "$T/h/bin/agent-call.sh"
call() {  # call <stage> — the prompt that stage's runner really received
  HARNESS="$T/h" PROJECT=demo-os OUTDIR="$T/out" \
  CG_ORIENT="CODEGRAPH AVAILABLE (index @ main deadbee, 42 symbols)" \
  VMAP_ORIENT="VERIFICATION MAP AVAILABLE (2 entries at docs/verification-map/)" \
  bash -c '
    set -uo pipefail
    HARNESS="'"$T"'/h"; PROJECT=demo-os
    . "'"$T"'/cc.sh"
    CC "$1" model 60 /dev/null "STAGE BODY TEXT"' _ "$1"
  cat "$T/out/$1.prompt"
}
for STAGE in plan execute review; do
  PR=$(call "$STAGE")
  grep -q 'VERIFICATION MAP AVAILABLE' <<<"$PR" \
    && ok || bad "$STAGE: the map availability line must be in the prompt"
  grep -q 'CODEGRAPH AVAILABLE' <<<"$PR" \
    && ok || bad "$STAGE: adding the map line must not displace the graph line"
  grep -q 'STAGE BODY TEXT' <<<"$PR" \
    && ok || bad "$STAGE: adding the map line must not displace the stage's own prompt"
done
# QA drives a browser against a deployment and gets its map pointer from its own
# prompt text, not from this line; fix rounds work from review findings.
for STAGE in qa fix; do
  ! grep -q 'VERIFICATION MAP AVAILABLE' <<<"$(call "$STAGE")" \
    && ok || bad "$STAGE must not receive the map orientation line"
done

# ---------- 8. render runs at build start, BEFORE the plan stage ------------
# The primer is worthless if it is written after the planner read the file.
python3 - "$RB" <<'PY' && ok || bad "run-build.sh must render the primer BEFORE the plan stage runs"
import sys
s = open(sys.argv[1]).read()
sys.exit(0 if s.index("verification-map.sh") < s.index("CC plan ") else 1)
PY
grep -q 'VMAP_ORIENT=$("$HARNESS/bin/verification-map.sh"' "$RB" \
  && ok || bad "run-build.sh must take its orientation line from verification-map.sh"

# ---------- 9. a render failure may never break a build ---------------------
# Extract the wiring block and run it with a render that fails outright.
python3 - "$RB" "$T/vmap-block.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
b = s.index("# --- VERIFICATION MAP (begin) ---")
e = s.index("# --- VERIFICATION MAP (end) ---")
open(sys.argv[2], "w").write(s[b:e])
PY
[ -s "$T/vmap-block.sh" ] && ok || bad "run-build.sh must delimit its verification-map block (begin/end markers)"
mkdir -p "$T/hb/bin"
cat > "$T/hb/bin/verification-map.sh" <<'STUB'
#!/bin/bash
echo "boom" >&2; exit 7
STUB
chmod +x "$T/hb/bin/verification-map.sh"
BLOCKOUT=$(bash -c 'set -uo pipefail; HARNESS="'"$T"'/hb"; PROJECT=demo-os; KEY=X-1; WT="'"$T"'/full"; BUILD="'"$T"'"
           STAMP() { echo stamp; }
           . "'"$T"'/vmap-block.sh"
           echo "SURVIVED: $VMAP_ORIENT"' 2>&1); BRC=$?
[ "$BRC" = 0 ] && ok || bad "a failing verification-map.sh must not abort the build path (rc $BRC)"
grep -q 'SURVIVED' <<<"$BLOCKOUT" \
  && ok || bad "the build must continue past a render failure (got: $BLOCKOUT)"
grep -q 'SURVIVED: VERIFICATION MAP NOT AVAILABLE' <<<"$BLOCKOUT" \
  && ok || bad "a failed orient must degrade to a NOT AVAILABLE line, never to an empty prompt prefix"

# ---------- 10. QA is pointed at the map, and preplan renders too -----------
# TEST-CHANGE (BH-7970): QA_PROMPT_FOR renders prompts/stages/qa.md, so the
# pointer lives in that template and the builder must render it (sp_render qa).
grep -q 'docs/verification-map' "$DIR/prompts/stages/qa.md" \
  && ok || bad "the QA stage prompt must point QA at the map for screens/selectors"
python3 - "$RB" "$DIR/prompts/stages/qa.md" <<'PY' && ok || bad "the map pointer must live inside the QA prompt builder, not somewhere else in the file"
import sys
s = open(sys.argv[1]).read()
b = s.index("QA_PROMPT_FOR()")
line = s[b:s.index("\n", b)]
sys.exit(0 if "sp_render qa" in line and "docs/verification-map" in open(sys.argv[2]).read() else 1)
PY
grep -q 'verification-map.sh' "$DIR/bin/run-preplan.sh" \
  && ok || bad "run-preplan.sh reads the same primer — it must render it too"
# fail-open is a property of the STATEMENT, so line continuations are joined
# before looking for the `||` — a `\`-wrapped call would otherwise read as fatal
# to this check and as fail-open to bash, and only one of them would be right.
python3 - "$DIR/bin/run-preplan.sh" <<'PY' && ok || bad "run-preplan's render must be fail-open (|| a fallback), never fatal"
import sys
s = open(sys.argv[1]).read().replace('\\\n', ' ')
i = s.index('verification-map.sh')
sys.exit(0 if '||' in s[i:s.index('\n', i)] else 1)
PY

# ---------- 12. onboarding + backfill are real artifacts, not promises ------
grep -q -- '--vmap-ticket' "$DIR/bin/load-project.sh" \
  && ok || bad "load-project.sh must offer the optional initial-map ticket step"
[ -s "$DIR/docs/VMAP-BACKFILL-TICKET.md" ] \
  && ok || bad "docs/VMAP-BACKFILL-TICKET.md (the ready-to-file backfill body) is missing"
grep -q 'verification-map-freshness' "$DIR/docs/VMAP-BACKFILL-TICKET.md" \
  && ok || bad "the backfill ticket must reference the guardrail that keeps the map fresh"
[ -s "$DIR/docs/verification-map/TEMPLATE.md" ] \
  && ok || bad "docs/verification-map/TEMPLATE.md (the per-feature file shape) is missing"
for NEED in 'selector' 'precondition' 'manual-only'; do
  grep -qi "$NEED" "$DIR/docs/verification-map/TEMPLATE.md" \
    && ok || bad "the template must define the '$NEED' part of a feature entry"
done

# ---------- 13. a repo that GENERATES its index still gets a real primer ----
# BH-1175. docs/verification-map/README.md became generated and git-ignored, and
# the primer is rendered with `--repo "$WT"` — the build WORKTREE, which
# `git worktree add --detach` creates with no ignored files in it. So the one
# checkout this file is written for is precisely the one that has no index, and
# before this case the primer said "this repo has not adopted the verification
# map" for a map with 113 entries, to every cromford build. The rule the
# primer states about itself ("not an invitation to go hunting for the file
# elsewhere") is what makes that a dead end rather than a nuisance.
#
# Two halves: the index is BUILT when the repo ships the generator, and when it
# cannot be built the map is still reported as adopted rather than absent.
G="$T/generated"
mkdir -p "$G/bin" "$G/docs/verification-map/index" "$G/docs/verification-map/entries"
printf '# Verification map — generated-os\n\nIntro that must survive.\n' > "$G/docs/verification-map/index/head.md"
printf '## Driving conventions\n\n- Poll an observable end-state, never a sleep.\n' > "$G/docs/verification-map/index/tail.md"
printf '%s\n' '| Billing | [billing.md](billing.md) | `bin/billing.sh` |' > "$G/docs/verification-map/entries/BH-1.md"
printf '# Billing\n\n**What it is:** a fixture feature entry.\n' > "$G/docs/verification-map/billing.md"
cp "$DIR/bin/verification-map-build.sh" "$G/bin/"; chmod +x "$G/bin/verification-map-build.sh"
printf '%s\n' 'docs/verification-map/README.md' > "$G/.gitignore"
[ -f "$G/docs/verification-map/README.md" ] \
  && bad "13 the fixture must start with NO index, or it proves nothing" || ok

render gen-os "$G" >/dev/null
GP=$(cat "$H/state/gen-os-context.md" 2>/dev/null)
grep -q 'VERIFICATION MAP (source:' <<<"$GP" \
  && ok || bad "13 a repo that generates its index must get a SOURCED map section, not ABSENT: $(grep -m1 'VERIFICATION MAP' <<<"$GP")"
grep -q 'has not adopted the verification map' <<<"$GP" \
  && bad "13 a map with entries must never render as 'not adopted' — that is what sent every build off to rediscover the screens" || ok
grep -q 'Intro that must survive' <<<"$GP" \
  && ok || bad "13 the generated index must be built and carried into the primer"
grep -qi 'poll an observable end-state' <<<"$GP" \
  && ok || bad "13 the driving conventions must be carried into the primer of a generating repo"

# The generator is gone: the index cannot be built at all. The map is STILL
# adopted — 1 entry — and the primer must say so and list it.
rm -f "$G/bin/verification-map-build.sh" "$G/docs/verification-map/README.md"
render gen2-os "$G" >/dev/null
GQ=$(cat "$H/state/gen2-os-context.md" 2>/dev/null)
grep -q 'has not adopted the verification map' <<<"$GQ" \
  && bad "13 a map with entries and no index must not read as 'not adopted'" || ok
grep -q 'billing.md' <<<"$GQ" \
  && ok || bad "13 with no index the primer must still list the entry files: $(grep -m1 'VERIFICATION MAP' <<<"$GQ")"

echo "verification-map-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
