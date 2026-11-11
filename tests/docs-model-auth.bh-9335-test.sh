#!/bin/bash
# tests/docs-model-auth.bh-9335-test.sh — BH-9335 (slice C0, Fixes 2 and 3):
# the operator docs and the env template show both model-auth paths.
#
#   D1  docs/OPERATOR-SETUP.md has no "only model credential" line
#   D2  the Anthropic accounts row names `claude setup-token`, an API key and a
#       Console spend limit
#   D3  the global.env block and the variable table say "one of the two"
#   D4  every repo path the doc tells the reader to copy exists: tracked in git,
#       or a generated path (docs/verification-map/index/tail.md) whose
#       generator command is within 3 lines of the copy instruction
#   E1  bin/render-env-example.sh prints exactly one commented
#       CLAUDE_CODE_OAUTH_TOKEN= line and one commented ANTHROPIC_API_KEY= line,
#       and no live line for either
#   E2  env-templates/README.md names the model credential blocks
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/docs-model-auth.bh-9335-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
DOC="$REPO/docs/OPERATOR-SETUP.md"
TAIL="$REPO/docs/verification-map/index/tail.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -s "$DOC" ] || { echo "FAIL: $DOC is missing or empty"; exit 1; }

# ── D1 ───────────────────────────────────────────────────────────────────────
hits=$(grep -nE 'only \*?model\*? credential' "$DOC")
[ -z "$hits" ] && ok || bad "D1 the doc still says the OAuth token is the only model credential: $hits"

# ── D2 ───────────────────────────────────────────────────────────────────────
row=$(grep -E '^\| \*\*Anthropic\*\* \|' "$DOC")
[ "$(grep -c . <<< "$row")" = 1 ] && ok || bad "D2 want one Anthropic accounts row, have: $row"
grep -qF 'claude setup-token' <<< "$row" && ok || bad "D2 the Anthropic row does not name claude setup-token"
grep -qF 'ANTHROPIC_API_KEY' <<< "$row" && ok || bad "D2 the Anthropic row does not name ANTHROPIC_API_KEY"
grep -qi 'spend limit' <<< "$row" && ok || bad "D2 the Anthropic row does not name a Console spend limit"
grep -qi 'metered' <<< "$row" && ok || bad "D2 the Anthropic row does not say the API key is metered"

# ── D3 ───────────────────────────────────────────────────────────────────────
blk=$(awk '/^\*\*`\/root\/harness\/env\/global.env`\*\*/{on=1} on&&/^```$/{n++; if(n==2) exit} on' "$DOC")
grep -qi 'one of the two' <<< "$blk" && ok || bad "D3 the global.env required block does not say one of the two"
trow=$(grep -E '^\| `CLAUDE_CODE_OAUTH_TOKEN`' "$DOC")
grep -qi 'one of the two' <<< "$trow" && ok || bad "D3 the variable table row does not say one of the two: $trow"

# ── D4: every copy path exists ───────────────────────────────────────────────
# The text from each "copy" word to the end of the line two lines later.
mapfile -t CP < <(awk '
  { line[NR]=$0 }
  END {
    for (i=1;i<=NR;i++) {
      p = match(line[i], /[Cc]opy[ \n]/); if (!p) { if (line[i] ~ /[Cc]opy$/) p=match(line[i], /[Cc]opy$/); }
      if (!p) continue
      txt = substr(line[i], p) " " line[i+1] " " line[i+2]
      while (match(txt, /`[^`]*`/)) {
        tok = substr(txt, RSTART+1, RLENGTH-2); txt = substr(txt, RSTART+RLENGTH)
        if (tok ~ /^[a-z][A-Za-z0-9_.-]*\/[A-Za-z0-9_.\/-]+\.[A-Za-z0-9]+$/) print i "\t" tok
      }
    }
  }' "$DOC")
[ "${#CP[@]}" -ge 3 ] && ok || bad "D4 found ${#CP[@]} copy paths, want >= 3 (the parser is broken)"
for e in "${CP[@]}"; do
  ln="${e%%$'\t'*}"; p="${e#*$'\t'}"
  if git -C "$REPO" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then ok; continue; fi
  gen=$(awk -F'|' -v p="\`$p\`" '{c=$2; gsub(/^ +| +$/,"",c)} c==p {g=$3; gsub(/^ +| +$/,"",g); gsub(/`/,"",g); print g; exit}' "$TAIL")
  if [ -z "$gen" ]; then bad "D4 line $ln: copy path $p is not tracked and not a generated path"; continue; fi
  lo=$((ln-3)); [ "$lo" -ge 1 ] || lo=1
  near=$(sed -n "${lo},$((ln+3))p" "$DOC")
  grep -qF -- "$gen" <<< "$near" && ok || bad "D4 line $ln: $p is generated, and '$gen' is not within 3 lines"
done

# ── E1: the rendered env template ────────────────────────────────────────────
R=$(HARNESS_TEST_SANDBOX=1 bash "$REPO/bin/render-env-example.sh"); rrc=$?
[ "$rrc" = 0 ] && ok || bad "E1 render-env-example.sh rc=$rrc"
[ "$(grep -c '^#CLAUDE_CODE_OAUTH_TOKEN=' <<< "$R")" = 1 ] && ok || bad "E1 want one #CLAUDE_CODE_OAUTH_TOKEN= line"
[ "$(grep -c '^#ANTHROPIC_API_KEY=' <<< "$R")" = 1 ] && ok || bad "E1 want one #ANTHROPIC_API_KEY= line"
live=$(grep -nE '^[[:space:]]*(export[[:space:]]+)?(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY)=' <<< "$R")
[ -z "$live" ] && ok || bad "E1 a live model credential line: $live"
if grep -qE 'sk-ant-[A-Za-z0-9]' <<< "$R"; then bad "E1 a key-shaped value in the template"; else ok; fi

# ── E2 ───────────────────────────────────────────────────────────────────────
grep -qF 'lanes/030-llm-runners.env.example' "$REPO/env-templates/README.md" && ok \
  || bad "E2 env-templates/README.md does not name lanes/030-llm-runners.env.example"

echo "docs-model-auth.bh-9335: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
