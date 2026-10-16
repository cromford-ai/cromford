#!/bin/bash
# tests/needs-human-classify.bh-3444-test.sh — the needs-human classifier
# (BH-3444, the BH-3433 classify slice): nh_classify, nh_on_block's guards and
# nh_prompt_field_note, sourced through the real bin/lib/needs-human.sh.
#   P1-P6  hits: the BH-3348 F1 text via --text, each fallback shape on a BLOCK,
#          and a real-format merged re-review whose final round asks for a hub run
#   N1-N14 negatives: APPROVE prose, NEEDS_HUMAN mid-line, negated need, quoted
#          and fenced lines, (minor)/non-blocking, past-tense hub history, an
#          earlier round, placeholders, the contract's C1 fixture, unreadable
#          input, a bare flaky-suite reason, an answered finding, a code path
#          that runs on the hub (N13) and "a human-readable" (N14)
#   S1-S3  the structured field: wins over a fallback line, needs no verdict,
#          collapses to one line
#   F1     the prompt sentence
#   O1-O2  nh_on_block prints nothing off an issues board or on a `none` review
#
# MUTATIONS (D1), run by hand in the build and recorded in its red.txt:
#   m1 drop the BLOCK gate in nh_classify          -> N1 red
#   m2 drop the `grep -viE "$NH_RE_NEG"` step      -> N3 / N5 / N12 red
#   m3 run the fallback before the structured field -> S1 red
#   m4 make _nh_final print the whole file          -> N7 red
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

CLASSIFY="$DIR/bin/lib/needs-human/classify.sh"
[ -r "$CLASSIFY" ] && ok || bad "D41: $CLASSIFY is missing"
# gh / gh_rest / alert-line / jobs on PATH record any call.
mkdir -p "$T/bin" "$T/h/bin" "$T/b"
for s in gh gh_rest alert-line jobs; do
  printf '#!/bin/bash\n: > "%s/called.%s"\nexit 0\n' "$T" "$s" > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
export PATH="$T/bin:$PATH"
# The placer stub records its argv; nh_on_block reaches it by rooted path.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/h/placer.calls"\nexit 0\n' "$T" > "$T/h/bin/needs-human-hold.sh"
chmod +x "$T/h/bin/needs-human-hold.sh"
export HARNESS="$T/h"
# shellcheck disable=SC1091
. "$DIR/bin/lib/needs-human.sh" || { echo "FAIL: could not source the lib"; exit 1; }

TAB=$'\t'
CL() { OUT=$(nh_classify "$@"); RC=$?; }
blockmd() { printf '%s\nTIER: 2\nVERDICT: BLOCK\n' "$2" > "$T/$1.md"; }

# ── P: hits ────────────────────────────────────────────────────────────────
F1="F1 … needs a human to run the probe (vs_publish + gh api status check) from the hub"
CL --text "$F1"
[ "$RC" = 0 ] && [ "$OUT" = "needs-human$TAB$F1" ] && ok || bad "P1: --text F1 gave '$OUT' rc $RC"

N=1
for LINE in "F2 needs a person to rotate the key" \
            "run the lead-verdict probe from the hub" \
            "the probe has to run as the hub conductor's GitHub identity" \
            "paste the curl output into the PR body"; do
  N=$((N+1)); blockmd "p$N" "## Findings
- a real code finding about the retry loop
$LINE"
  CL "$T/p$N.md"
  [ "$RC" = 0 ] && [ "$OUT" = "needs-human$TAB$LINE" ] && ok || bad "P2-P4: shape '$LINE' gave '$OUT' rc $RC"
done
# P5 (BH-7123): "the build box lacks <credential>" is no longer a shape. It
# describes a verification the box could not run, which the review levels make
# a `[NOTE] not verified here`, never a hold (it was 9 of 37 holds in
# 2026-09-25..10-16). Only an explicit NEEDS_HUMAN: line asks for a person now.
N=$((N+1)); blockmd "p$N" "## Findings
- a real code finding about the retry loop
the build box lacks the HARNESS app key credential"
CL "$T/p$N.md"
[ "$RC" = 1 ] && [ "$OUT" = none ] && ok || bad "P5: the credential shape must no longer classify (gave '$OUT' rc $RC)"
blockmd "p$N-b" "## Findings
- [NOTE] not verified here: the build box lacks the Clerk dev keys, so e2e did not run
- a real code finding; this needs a human to check the vendor console
NEEDS_HUMAN: add the live Stripe key on Vercel before go-live"
CL "$T/p$N-b.md"
[ "$RC" = 0 ] && [ "$OUT" = "needs-human${TAB}add the live Stripe key on Vercel before go-live" ] && ok || bad "P5b: the explicit NEEDS_HUMAN line must still win (gave '$OUT' rc $RC)"

# P6: a merged re-review in the real format (review.sh's header, tags stripped).
cat > "$T/p6.md" <<'EOF'
## Review — BH-3348

F1. The lead-verdict gate has no probe evidence in validate.txt (D6).
F2. The new suite never drives the production entry point (D2).

TIER: 2
VERDICT: BLOCK

=== MERGED RE-REVIEW after the single fix round (head 5b35bacc) ===
## Re-review

F2 is fixed: the suite now runs the real bin/lead-verdict.sh.

F1 stands. The builder cannot run this probe from a pool box.
- **To clear it:** the hub runs `bin/vs-publish.sh --dry-run` and `gh api repos/example-org/cromford/commits/HEAD/status`, and both commands and their outputs go into the PR body.

VERDICT-REVIEW BLOCK
TIER: 2
VERDICT: BLOCK
EOF
CL "$T/p6.md"; P6ACT=${OUT#*"$TAB"}
[ "$RC" = 0 ] && [ "${OUT%%"$TAB"*}" = needs-human ] && [[ "$P6ACT" == "- To clear it:"* ]] && [ "${#P6ACT}" -le 160 ] \
  && ok || bad "P6: merged re-review gave '$OUT' rc $RC"

# ── N: negatives ───────────────────────────────────────────────────────────
printf '%s\n' "## Review" "this does not look like it needs a human" "run it from the hub later" \
  "see NEEDS_HUMAN: x" "TIER: 1" "VERDICT: APPROVE" > "$T/n1.md"
CL "$T/n1.md"; [ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "N1: APPROVE review gave '$OUT' rc $RC"
blockmd n2 "the note mentions NEEDS_HUMAN: in passing"
CL "$T/n2.md"; [ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "N2: mid-line NEEDS_HUMAN gave '$OUT' rc $RC"
blockmd n3 "Finding 2 does not need a human"
CL "$T/n3.md"; [ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "N3: negated need gave '$OUT' rc $RC"
blockmd n4 '> needs a human from the hub
```
needs a human from the hub
```'
CL "$T/n4.md"; [ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "N4: quoted/fenced gave '$OUT' rc $RC"
blockmd n5 "run the migration from the hub (minor)
non-blocking: paste the output into the PR body"
CL "$T/n5.md"; [ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "N5: minor/non-blocking gave '$OUT' rc $RC"
blockmd n6 "we re-ran the suite on the hub box"
CL "$T/n6.md"; [ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "N6: past-tense hub gave '$OUT' rc $RC"
printf '%s\n' "F1 has no probe." "NEEDS_HUMAN: run the probe from the hub" "TIER: 2" "VERDICT: BLOCK" \
  "" "=== MERGED RE-REVIEW after the single fix round (head abc1234) ===" \
  "F3. the retry loop is unbounded (D21)." "TIER: 2" "VERDICT: BLOCK" > "$T/n7.md"
CL "$T/n7.md"; [ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "N7: an earlier round's field gave '$OUT' rc $RC"
blockmd n8 "NEEDS_HUMAN: none
NEEDS_HUMAN: <one-line action>
NEEDS_HUMAN: N/A."
CL "$T/n8.md"; [ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "N8: placeholders gave '$OUT' rc $RC"
printf 'NEEDS-HUMAN: set the Vercel env\nFRAUD: false-completion\nthe human step is owed\nVERDICT: BLOCK\n' > "$T/n9.md"
CL "$T/n9.md"; [ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "N9: contract C1 fixture gave '$OUT' rc $RC"
CL "$T/missing.md"; [ -z "$OUT" ] && [ "$RC" = 2 ] && ok || bad "N10: missing file gave '$OUT' rc $RC"
CL; [ -z "$OUT" ] && [ "$RC" = 2 ] && ok || bad "N10: no args gave '$OUT' rc $RC"
CL --text; [ -z "$OUT" ] && [ "$RC" = 2 ] && ok || bad "N10: --text with no string gave '$OUT' rc $RC"
CL --text "flaky suite"; [ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "N11: flaky suite gave '$OUT' rc $RC"
blockmd n12 "F1 was answered: it needs a human from the hub"
CL "$T/n12.md"; [ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "N12: answered finding gave '$OUT' rc $RC"
# N13/N14: where code runs is not an ask, and "human-readable" is not a human.
for LINE in "F2. merge-sweep.sh runs on the hub every tick, so this unguarded loop blocks all lanes (D14)." \
            "F2. When the placer runs on the hub it re-reads the thread; a race here double-posts." \
            "F1. The test only runs locally; it should also run in CI, not only from the hub." \
            "F2. This needs a human-readable error message." \
            "F2. The alert needs a human-facing summary line." \
            "F3. It needs a person-level audit trail."; do
  blockmd n13 "$LINE"
  CL "$T/n13.md"; [ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "N13/N14: '$LINE' gave '$OUT' rc $RC"
  CL --text "$LINE"; [ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "N13/N14: --text '$LINE' gave '$OUT' rc $RC"
done

# ── S: the structured field ────────────────────────────────────────────────
blockmd s1 "needs a human to run the probe from the hub
NEEDS_HUMAN: set VERCEL_TOKEN in prod"
CL "$T/s1.md"; [ "$RC" = 0 ] && [ "$OUT" = "needs-human${TAB}set VERCEL_TOKEN in prod" ] && ok || bad "S1: gave '$OUT' rc $RC"
printf '%s\n' "## Review" "NEEDS_HUMAN: apply the migration on prod" > "$T/s2.md"
CL "$T/s2.md"; [ "$RC" = 0 ] && [ "$OUT" = "needs-human${TAB}apply the migration on prod" ] && ok || bad "S2: no-verdict field gave '$OUT' rc $RC"
blockmd s3 "NEEDS_HUMAN:${TAB}paste${TAB} the  output "
CL "$T/s3.md"; [ "$RC" = 0 ] && [ "$OUT" = "needs-human${TAB}paste the output" ] && [ "$(wc -l <<<"$OUT")" = 1 ] \
  && ok || bad "S3: whitespace field gave '$OUT' rc $RC"

# ── F: the prompt sentence ─────────────────────────────────────────────────
OUT=$(nh_prompt_field_note); RC=$?
[ "$RC" = 0 ] && [ "$(wc -l <<<"$OUT")" = 1 ] && [ "${OUT:0:1}" = " " ] && [ -n "${OUT// /}" ] \
  && [[ "$OUT" == *"NEEDS_HUMAN: <one-line action>"* ]] && [[ "$OUT" == *"TIER:"* ]] \
  && ok || bad "F1: nh_prompt_field_note gave '$OUT' rc $RC"

# ── O: nh_on_block's guards ────────────────────────────────────────────────
OUT=$(nh_on_block p "" "$T/p6.md" "$T/b"); RC=$?
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$T/b/needs-human.txt" ] && ok || bad "O1: no issue gave '$OUT' rc $RC"
OUT=$(nh_on_block p 7 "$T/n9.md" "$T/b"); RC=$?
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$T/b/needs-human.txt" ] && [ ! -e "$T/h/placer.calls" ] \
  && ok || bad "O2: a none review gave '$OUT' rc $RC"

[ -z "$(find "$T" -maxdepth 1 -name 'called.*')" ] && ok || bad "a gh/alert stub was called: $(ls "$T"/called.* 2>/dev/null)"

echo "needs-human-classify.bh-3444: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
