#!/bin/bash
# tests/arch-contract-test.sh — Wave C: the agent-architecture contract.
#
# WHAT THIS WAVE ENCODES, and therefore what these assertions are protecting.
# An under-specified agent optimizes for what is in its context: it copies the
# nearest pattern, edits the file that is already open, takes the shortest path
# that compiles, avoids deleting code whose callers it cannot see, and follows
# an instruction even when doing so breaks an invariant nobody put in front of
# it. None of that is a skill problem and none of it is fixed by asking more
# nicely in a prompt. The contract's job is to make the locally-obvious change
# the globally-correct one, and to make the unsafe shortcut fail MECHANICALLY
# with an error that names the supported pattern.
#
# So the properties pinned here are the ones that decide whether this wave is
# machinery or decoration:
#
#   1. the template really carries all five rules, a place for the repo's own
#      nouns, and a backing table that marks an unenforced rule as DEBT rather
#      than letting prose pass for enforcement;
#   2. the audit brief refuses to propose a blocking check that fails the
#      objectivity test, refuses to land any check itself, and cites the ONE
#      escape hatch instead of inventing a second;
#   3. `--arch-ticket` files exactly one ticket per repo — the dedup is an
#      EXACT title match, driven here against a fake `gh`, because a substring
#      match and a stale-index `--search` both put a duplicate ticket on
#      someone's board;
#   4. the contract this template produces is actually picked up by Wave B's
#      renderer. That is the whole delivery path: a filename or a heading style
#      the renderer does not recognize means the audit's output never reaches a
#      planner, and nothing would have told us.
#
# Wave B's own absent-case assertions live in tests/verification-map-test.sh and
# are deliberately not duplicated or disturbed here.
#
# Run from anywhere: tests/arch-contract-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TPL="$DIR/docs/AGENT-ARCHITECTURE-TEMPLATE.md"
BRIEF="$DIR/prompts/arch-audit.md"
TICKET="$DIR/docs/ARCH-AUDIT-TICKET.md"
LP="$DIR/bin/load-project.sh"
VM="$DIR/bin/verification-map.sh"
FIX="$DIR/catalog/fixtures"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- 1. the template exists and is shaped like a contract -------------
[ -s "$TPL" ] && ok || bad "docs/AGENT-ARCHITECTURE-TEMPLATE.md is missing or empty"

# Five rules, as five markdown headings. Heading shape is not cosmetic here:
# bin/verification-map.sh lists an AGENT_ARCHITECTURE.md's sections by grepping
# '^#{1,6} ', so a rule written as bold text or a list item is a rule the
# primer never shows a planner.
# No `|| echo 0`: grep -c already PRINTS 0 when it matches nothing and exits 1,
# so the fallback appended a second zero and the failure message read "found
# 0 0". The empty case that actually needs a default is an unreadable file.
NRULES=$(grep -cE '^#{1,6} +Rule [1-5] ' "$TPL" 2>/dev/null); [ -n "$NRULES" ] || NRULES=0
[ "$NRULES" = 5 ] && ok || bad "the template must carry exactly five '# Rule N ' headings (found $NRULES)"

# Each rule by the thing it actually says, matched against the RULE HEADINGS
# ONLY — not the whole file.
#
# Found by mutation: softening `### Rule 3 — One obvious writer per durable
# value` to `### Rule 3 — Writers` left the suite green, because the phrase
# still appeared further down in the mechanical-backing table's row label. A
# rule can therefore be gutted while the table that is supposed to account for
# it goes on naming it, which is the exact drift this file is here to catch.
HEADINGS=$(grep -E '^#{1,6} +Rule [1-5] ' "$TPL" 2>/dev/null)
while IFS='|' read -r what pat; do
  grep -qiE "$pat" <<<"$HEADINGS" \
    && ok || bad "no rule HEADING states the '$what' rule (no match for /$pat/ in the five headings)"
done <<'RULES'
conventional path is cheaper|cheaper
forbidden dependencies fail mechanically|fail(s)? mechanically
one obvious writer per durable value|one obvious writer
new work is isolated files, not branches in shared roots|isolated file
exceptions are narrow, explicit, reviewed|exception
RULES

# The repo fills in its own nouns. A contract that talks about "modules" in the
# abstract is one every agent reads past; a contract that names THIS repo's
# Feature/Entrypoint equivalents is one it can obey.
grep -qiE '^#{1,6} +Named nouns' "$TPL" \
  && ok || bad "the template must carry a 'Named nouns' section for the repo to fill in"
grep -qE '<[A-Z][A-Z_ -]+>' "$TPL" \
  && ok || bad "the named-nouns section must ship fill-in placeholders (<LIKE_THIS>), not prose to be rewritten"

# ---------- 2. the mechanical-backing table, including honest debt -----------
grep -qiE '^#{1,6} +Mechanical backing' "$TPL" \
  && ok || bad "the template must carry a 'Mechanical backing' section"
# A three-column table: rule -> the check that enforces it -> where that check
# lives. Rendered as a markdown table, with a separator row.
grep -qE '^\|[^|]*\|[^|]*\|[^|]*\|' "$TPL" \
  && ok || bad "mechanical backing must be a table (rule | check | ...)"
grep -qE '^\|[ :-]+\|[ :-]+\|' "$TPL" \
  && ok || bad "the mechanical-backing table needs a markdown separator row"
NBACK=$(grep -cE '^\|[^|]*Rule [1-5][^|]*\|' "$TPL" 2>/dev/null); [ -n "$NBACK" ] || NBACK=0
[ "$NBACK" = 5 ] && ok || bad "the backing table must carry a row for each of the five rules (found $NBACK)"
# The honest half. A rule with no check is DEBT, written down as debt. Without
# this word the table becomes a place to describe prose as if it enforced
# something, which is the exact failure the whole wave exists to end.
grep -q 'PROSE-ONLY (debt)' "$TPL" \
  && ok || bad "the backing table must offer the honest 'PROSE-ONLY (debt)' marking for an unenforced rule"

# ---------- 3. project-agnostic: stacks appear only as examples --------------
# The template is copied into repos we have not seen. A Next.js path or an
# Electron process name stated as fact in a rule is a rule that is false in
# most repos it lands in — and a contract that is visibly wrong on line one is
# a contract nobody reads to line two.
STACKLEAK=$(grep -nE 'Next\.js|Electron|Prisma|Django|Rails|React Native' "$TPL" \
  | grep -viE 'e\.g\.|example|for instance|<!--' || true)
[ -z "$STACKLEAK" ] && ok || bad "stack-specific names must appear only as marked examples: $STACKLEAK"
grep -qE '^#{1,6} +Rule [1-5] [^|]*(Next\.js|Electron|Prisma)' "$TPL" \
  && bad "a rule heading must not name a specific stack" || ok

# ---------- 4. the audit brief's invariants ---------------------------------
[ -s "$BRIEF" ] && ok || bad "prompts/arch-audit.md is missing or empty"

# The framing the whole brief hangs on.
grep -qi 'under-specified' "$BRIEF" \
  && ok || bad "the brief must frame the problem as the under-specified agent's incentives"
for AXIS in shortcut writer import 'shared root'; do
  grep -qi "$AXIS" "$BRIEF" \
    && ok || bad "the brief's discovery questions must cover '$AXIS'"
done

# The objectivity test, in the words the miner already uses (guardrails/README.md,
# bin/rule-miner.sh): measurable observation + named tool + explicit threshold.
# A proposed check that fails it belongs in prose, not in blocking CI.
for TERM in 'measurable observation' 'named tool' 'explicit threshold'; do
  grep -qi "$TERM" "$BRIEF" \
    && ok || bad "the brief must state the objectivity test's '$TERM' requirement"
done
grep -qi 'false.positive' "$BRIEF" \
  && ok || bad "the brief must require a near-zero false-positive rate before a check may BLOCK"
grep -qi 'judgment' "$BRIEF" \
  && ok || bad "the brief must send judgment-shaped rules to the contract prose, not to a check"

# The refusal that keeps this an audit and not a deploy. An audit that can land
# a check has turned someone's CI red without a review, which is how a
# guardrail gets deleted wholesale on the Friday after.
grep -qiE 'never lands|does not land|never merge' "$BRIEF" \
  && ok || bad "the brief must state that the audit NEVER lands checks directly"
grep -qi 'guardrails/lib/escape-hatch.sh' "$BRIEF" \
  && ok || bad "the brief must cite the ONE shared escape hatch (guardrails/lib/escape-hatch.sh), not invent a second"

# Required output, named exactly. The renderer reads one path and one path only.
grep -q 'AGENT_ARCHITECTURE.md' "$BRIEF" \
  && ok || bad "the brief must name AGENT_ARCHITECTURE.md as the required output"
grep -q 'docs/AGENT-ARCHITECTURE-TEMPLATE.md' "$BRIEF" \
  && ok || bad "the brief must point at the template it is required to follow"

# ---------- 5. the backfill ticket body -------------------------------------
[ -s "$TICKET" ] && ok || bad "docs/ARCH-AUDIT-TICKET.md is missing or empty"
grep -q '^---$' "$TICKET" \
  && ok || bad "the ticket file needs the '---' divider (everything below it is the issue body)"
grep -q 'prompts/arch-audit.md' "$TICKET" \
  && ok || bad "the ticket must name the audit brief it is asking someone to run"
grep -qi 'acceptance test' "$TICKET" \
  && ok || bad "the ticket must carry acceptance tests (house plan contract)"
grep -qi 'out of scope' "$TICKET" \
  && ok || bad "the ticket must carry an out-of-scope section"
# Process substitution, not a pipe: `grep -q` exits at the first match and
# SIGPIPEs its upstream, and under `set -o pipefail` that kill reads as a failed
# assertion at random. tests/rollup-crash-loud-test.sh sweeps the whole suite for
# the piped form — it caught this line.
grep -qiE 'land|merge' <(grep -iA 12 'out of scope' "$TICKET") \
  && ok || bad "out of scope must explicitly exclude landing a check from this ticket's PR"

# THE DRIFT THIS PINS (review finding B1). The ticket is a derivative of
# prompts/arch-audit.md, and the brief's single most load-bearing refusal is
# that the audit NEVER lands a check — proposals ride the guardrail-promotion
# PR, reviewed by a person. The first draft of this ticket quietly licensed the
# opposite: "for each check the audit proposes AND THIS PR ADOPTS", "any check
# adopted here", "(fixed here...)". Read together those turn the audit PR into
# an adoption PR, which is exactly the un-reviewed CI change the brief exists to
# prevent — and nothing mechanical would have caught it, because every
# individual sentence reads as reasonable.
#
# So: no adoption-in-THIS-PR language anywhere in the ticket. Scoped to the
# acceptance + escape-hatch sections, where the drift actually lives and where
# a false positive is least likely; the Out of scope section legitimately says
# "do not adopt here" and must stay sayable.
python3 - "$TICKET" <<'PY' && ok || bad "the ticket must not license adopting a check in this ticket's own PR (review finding B1)"
import re, sys
s = open(sys.argv[1]).read()
lo = s.lower()

def span(start_pat, end_pat):
    a = lo.find(start_pat)
    b = lo.find(end_pat)
    return None if (a < 0 or b < 0 or b <= a) else s[a:b]

# The negative half runs over the WHOLE issue body (everything below the `---`
# divider) up to Out of scope. Scoped to acceptance+hatch it missed the
# Deliverable's own "(fixed here...)", which is one of the four sites the review
# named — the drift is a property of the ticket, not of one section of it. Out
# of scope stays excluded on purpose: it legitimately says "do not adopt from
# this PR", and that sentence must stay sayable.
div = s.find('\n---\n')
body_at = 0 if div < 0 else div
end = lo.find('## out of scope')
if end <= body_at:
    print("could not locate the body..out-of-scope span", file=sys.stderr)
    sys.exit(1)
neg = s[body_at:end]
# BOTH word orders. The first version of this pin only matched
# "adopts ... this PR" and sailed straight past the actual drifted sentence,
# "for each check the audit proposes and THIS PR ADOPTS" — the exact string it
# was written to catch. A one-directional regex against prose is a coin flip.
PATTERNS = [
    r'\badopts?\b[^.\n]{0,60}\b(this pr|here)\b',
    r'\b(this pr|here)\b[^.\n]{0,60}\badopts?\b',
    r'\badopted\s+here\b',
    r'\bfixed\s+here\b',
]
hits = [l for l in neg.split('\n') if any(re.search(p, l, re.I) for p in PATTERNS)]
if hits:
    print("adoption-in-this-PR language:\n  " + "\n  ".join(hits), file=sys.stderr)
    sys.exit(1)

# The positive half, scoped to the ACCEPTANCE section alone. Scoped wider it was
# satisfied by the escape-hatch section's own "promotion PR" mention, so deleting
# the acceptance bullet's pointer entirely still passed — "no adoption language"
# is trivially true of a sentence that says nothing, and silence is how this
# drifts back.
acc = span('## acceptance test', '## escape hatch')
if acc is None:
    print("could not locate the acceptance section", file=sys.stderr)
    sys.exit(1)
sys.exit(0 if re.search(r'promotion pr|adoption pr|later\b[^.\n]{0,40}pr', acc, re.I) else 1)
PY

# ---------- 6. --arch-ticket: the flag, and the block it gates --------------
grep -q -- '--arch-ticket' "$LP" \
  && ok || bad "load-project.sh must offer the optional --arch-ticket step"
grep -qE '^#.*--arch-ticket|--arch-ticket\)' "$LP" \
  && ok || bad "--arch-ticket must be a parsed flag, not just a mention"

# Extract the real block and execute it against a fake gh — a test of a retyped
# copy proves the copy (tests/verification-map-test.sh made the same call).
python3 - "$LP" "$T/arch-block.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
b = s.index("# --- ARCH TICKET (begin) ---")
e = s.index("# --- ARCH TICKET (end) ---")
open(sys.argv[2], "w").write(s[b:e])
PY
[ -s "$T/arch-block.sh" ] && ok || bad "load-project.sh must delimit its arch-ticket block (begin/end markers)"

# The title is single-sourced from the block itself: a test carrying its own
# copy of the string would keep passing after the two drifted apart, which is
# precisely the duplicate-ticket bug it is here to prevent.
ATITLE=$(sed -n 's/^[[:space:]]*ATITLE="\(.*\)"$/\1/p' "$T/arch-block.sh" | head -1)
[ -n "$ATITLE" ] && ok || bad "could not read the ticket title out of the arch block"

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
. "$GH_CLI_REST_ADAPTER" || exit 1   # BH-8962: the REST create, from the issue create arm below
gh_cli_rest_create "$0" "$@" && exit 0
if [ "$1 $2" = "api -i" ]; then   # TEST-CHANGE BH-1651: gh_rest_issue_list
  printf 'HTTP/2 200\r\n\r\n'
  if [ -n "${GH_TITLES:-}" ]; then printf '%s\n' "$GH_TITLES" | jq -R '{title:.}' | jq -cs .; else echo '[]'; fi
  exit 0
fi
if [ "$1 $2" = "issue list" ]; then
  [ -n "${GH_TITLES:-}" ] && printf '%s\n' "$GH_TITLES"
  exit 0
fi
[ "$1 $2" = "issue create" ] && echo "https://github.com/owner/repo/issues/1"
exit 0
STUB
chmod +x "$T/bin/gh"

run_arch() {  # run_arch <log> <titles gh should report as already on the board>
  # HARNESS in scratch: gh-rest-list.sh's ETag cache writes and prunes under
  # $HARNESS/state/gh-etag, and an unset HARNESS defaults to /root/harness.
  ( cd "$DIR" && PATH="$T/bin:$PATH" GH_LOG="$1" GH_TITLES="$2" HARNESS="$T/h" \
    GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh" \
    bash -c 'set -euo pipefail
      SLUG=owner/repo; PROJECT=demo-os; ARCH_TICKET=1
      . bin/lib/gh-rest-list.sh
      . bin/lib/tracker/gh-issue-create.sh
      . "'"$T"'/arch-block.sh"' ) 2>&1
}

# 6a. empty board -> exactly one ticket, with the label the watcher gates on
L="$T/gh-new.log"; : > "$L"
OUT=$(run_arch "$L" "")
grep -q 'issue create' "$L" \
  && ok || bad "a board with no arch ticket must get one filed (got: $OUT)"
grep -qF -- "--title $ATITLE" "$L" \
  && ok || bad "the filed ticket must carry the exact title the dedup looks for"
grep -q -- '--label ai-build' "$L" \
  && ok || bad "the ticket must be labeled ai-build or the watcher never sees it"
[ "$(grep -c 'issue create' "$L")" = 1 ] \
  && ok || bad "exactly one ticket per run"

# 6b. the ticket already there -> nothing filed. This is the arm that keeps a
# re-run of an onboarding command from stacking duplicates on a client board.
L="$T/gh-dup.log"; : > "$L"
OUT=$(run_arch "$L" "some other issue
$ATITLE
yet another")
grep -q 'issue create' "$L" \
  && bad "an existing arch ticket must NOT be filed again (got: $OUT)" || ok
grep -qi 'already exists' <<<"$OUT" \
  && ok || bad "the skip must say why out loud (got: $OUT)"

# 6c. a near-miss title is NOT a match. Substring/fuzzy matching is what makes a
# dedup silently skip a repo that never got its ticket.
L="$T/gh-near.log"; : > "$L"
run_arch "$L" "$ATITLE (superseded)" >/dev/null
grep -q 'issue create' "$L" \
  && ok || bad "a title that merely CONTAINS the ticket title must not count as the ticket"

# 6d. the dedup reads the listing, not GitHub's search index (which lags on a
# just-created issue and stems its tokens).
# Comments are stripped first: the block's comment explains WHY `--search` is
# wrong, and a check that cannot tell the explanation from the call would force
# the reasoning out of the file to stay green.
CODE=$(grep -v '^[[:space:]]*#' "$T/arch-block.sh")
grep -q 'gh_rest_issue_list' <<<"$CODE" && ! grep -q -- '--search' <<<"$CODE" \
  && ok || bad "dedup must use the issue LISTING with an exact match, never --search"
grep -q 'grep -qxF' "$T/arch-block.sh" \
  && ok || bad "the title comparison must be exact and literal (grep -qxF)"

# 6e. tests never file. The block only ever runs under its own flag.
grep -qE 'ARCH_TICKET.*=.*1|\[ "\$ARCH_TICKET" = 1 \]' "$T/arch-block.sh" \
  && ok || bad "the block must be gated on ARCH_TICKET"

# ---------- 7. Wave B's renderer really picks this contract up --------------
# The delivery path, end to end: the audit writes a contract in the template's
# shape, and the primer a planner reads shows it. A filename or heading style
# the renderer does not recognize breaks this silently — the audit would run,
# the PR would merge, and no planner would ever see a line of it.
H="$T/harness"; mkdir -p "$H/state"
cp -R "$FIX/verification-map/full" "$T/repo"

# 7a. the TEMPLATE ITSELF, dropped in as the contract. This is what pins the
# template's own heading style and the exact filename against the renderer.
cp "$TPL" "$T/repo/AGENT_ARCHITECTURE.md" 2>/dev/null \
  && ok || bad "could not place the template as the fixture repo's contract"
HARNESS="$H" "$VM" render arch-os --repo "$T/repo" >/dev/null 2>&1
P=$(cat "$H/state/arch-os-context.md" 2>/dev/null)
grep -q 'AGENT ARCHITECTURE (source: AGENT_ARCHITECTURE.md)' <<<"$P" \
  && ok || bad "a template-shaped contract at the repo root must render as a SOURCED section"
# Keyed on a heading only THIS template has: the Wave B fixture ships its own
# AGENT_ARCHITECTURE.md, so an assertion satisfied by either file would pass
# even with the template missing entirely — which is how it read on the first
# red run.
grep -q 'Named nouns' <<<"$P" \
  && ok || bad "the primer must show the template's own sections (not merely some contract that was already there)"
grep -q 'agent-architecture=yes' <<<"$P" \
  && ok || bad "the primer header's source flags must report the contract present"
grep -qE 'Rule 1 ' <<<"$P" \
  && ok || bad "the renderer lists sections by markdown heading — the template's rules must be headings it finds"
grep -qE 'ABSENT.*AGENT_ARCHITECTURE' <<<"$P" \
  && bad "a present contract must never render ABSENT" || ok

# 7b. a FILLED-IN contract (the real output shape of an audit) renders the
# repo's own nouns, not the template's placeholders.
cp "$FIX/arch-contract/AGENT_ARCHITECTURE.filled.md" "$T/repo/AGENT_ARCHITECTURE.md" 2>/dev/null \
  && ok || bad "catalog/fixtures/arch-contract/AGENT_ARCHITECTURE.filled.md is missing"
HARNESS="$H" "$VM" render arch-os --repo "$T/repo" >/dev/null 2>&1
F=$(cat "$H/state/arch-os-context.md" 2>/dev/null)
grep -q 'AGENT ARCHITECTURE (source: AGENT_ARCHITECTURE.md)' <<<"$F" \
  && ok || bad "a filled-in contract must render as a sourced section"
grep -qE 'Rule 1 ' <<<"$F" \
  && ok || bad "a filled-in contract's rule headings must reach the primer"
grep -q 'Named nouns in demo-os' <<<"$F" \
  && ok || bad "a filled contract names the REPO's nouns — the primer must carry that heading, not the template's placeholder one"
grep -q 'Read it in full' <<<"$F" \
  && ok || bad "the primer must tell the planner to read the contract itself, not just list its headings"

# ---------- 8. the skill documents both, and the plan handoff cites rules ----
SK="$DIR/skills/harness/SKILL.md"
grep -q 'docs/ARCH-AUDIT-TICKET.md' "$SK" \
  && ok || bad "skills/harness/SKILL.md must list the arch-audit ticket template beside the vmap one"
grep -q -- '--arch-ticket' "$SK" \
  && ok || bad "the skill must document the --arch-ticket onboarding flag"
grep -qi 'AGENT_ARCHITECTURE.md' "$SK" \
  && ok || bad "the skill's plan handoff must tell planners which contract to cite"
python3 - "$SK" <<'PY' && ok || bad "the plan-handoff section must require plans to cite the contract rules they touch"
import re, sys
# The slice is enforced, not merely claimed. An earlier version of this block
# carried the comment "the requirement has to live in the handoff section" and
# then searched the WHOLE file — so the requirement could drift into any
# unrelated section and the assertion would still pass while its comment said
# otherwise. A test that describes a stricter check than it performs is worse
# than the loose check alone: the next reader trusts the comment.
s = open(sys.argv[1]).read()
m = re.search(r'^##\s+\d*\.?\s*plan\b.*$', s, re.I | re.M)
if not m:
    print("no '## ... plan ...' handoff section in SKILL.md", file=sys.stderr)
    sys.exit(1)
nxt = re.search(r'^##\s', s[m.end():], re.M)
section = s[m.end(): m.end() + nxt.start()] if nxt else s[m.end():]
sys.exit(0 if re.search(r'cite[^.\n]{0,80}(contract|rule)', section, re.I) else 1)
PY

echo "arch-contract-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
