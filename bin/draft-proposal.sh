#!/bin/bash
# draft-proposal.sh <project> <idea-dir> — produce prd.md + ticket.html +
# mockup.html + screenshots + cockpit assets for the idea in <idea-dir>/idea.json.
# Shared by run-product.sh (selected ideas) and product-cmd.sh (resurrecting a
# candidate that was never drafted). Exit 0 only when PRD + mockup both exist.
set -uo pipefail
PROJECT="${1:?project}"; IDIR="${2:?idea-dir}"
HARNESS=/root/harness
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
REPO="/root/repos/$PROJECT"
ALERTS="$HARNESS/logs/ALERTS.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

set -a
[ -f "$HENV/global.env" ] && . "$HENV/global.env"
[ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"
set +a
# >>> model-route (BH-1510.2): model_routes roles `product.prd` and
# `product.mockup` — the same two stages run-product.sh names — with PRD_MODEL /
# MOCKUP_MODEL still winning when set. No route = rc 75 before either stage is
# bought, alerted by bin/lib/model-route.sh; nothing is guessed.
. "$HARNESS/bin/lib/lane-model.sh"
PRD_MODEL=$(lane_model PRD_MODEL product.prd "$PROJECT") \
  && MOCKUP_MODEL=$(lane_model MOCKUP_MODEL product.mockup "$PROJECT") \
  || { echo "$(STAMP) [$PROJECT] draft: no model route for product.prd/product.mockup — not drafted" >> "$ALERTS"; exit 75; }
# <<< model-route

[ -s "$IDIR/idea.json" ] || { echo "$(STAMP) [$PROJECT] draft: no idea.json in $IDIR" >> "$ALERTS"; exit 1; }
IDEA=$(cat "$IDIR/idea.json")
SLUG=$(jq -r '.slug' <<<"$IDEA")

PRD_PROMPT="PRD stage for a client feature proposal. Idea (JSON): $IDEA
Repo (read for real model/route/vocabulary accuracy): $REPO — CLAUDE.md, prisma/schema.prisma (or the prisma/schema/ folder), the nav/app-map, existing screens.
Write TWO files:
1. $IDIR/prd.md — internal PRD: Problem & evidence (quote the evidence pointers) / Proposed solution / Backend requirements (additive-only Prisma models+columns, API routes, crons, RLS note for new tables, indexes for every query on a new table in the same migration (proven with EXPLAIN on seeded data), no per-row correlated subquery over a large table, a retention rule (scheduled delete/archive, window in a settings row) for every growing table) / Frontend requirements (screens, nav placement, sortable tables + full drill-down + mobile compliance) / Acceptance criteria (concrete, testable) / Effort in AI sessions / Out of v1. Include the idea's department/role/process and its DERISK-UNCLOG-SCALE bucket + why.
2. $IDIR/ticket.html — the client-facing ticket description (sanitized-HTML-safe: p/h2/h3/ul/li/strong/a/img only, no scripts/styles). Structure: what we noticed (their vocabulary, cite the evidence conversationally) → what we propose (2-3 short paragraphs; OPEN in the idea's framework voice by bucket — derisk: 'this removes something that can hurt you…', unclog: 'work piles up here today; this clears the bottleneck…', scale: 'this is a growth play — more output without more headcount…') → what you'll see (bullet the screens/flows) → literal token {{MOCKUP_BLOCK}} on its own line → 'If you like this direction, reply here and we'll build it. Want changes? Tell us what to adjust.' De-AI voice: warm, first-person plural, direct, near-zero em dashes, no AI-isms. Keep it under 6000 characters.
Do not modify any repo files. Final line: PRD_DONE or PRD_FAILED <reason>."
"$HARNESS/bin/agent-call.sh" prd "$PROJECT" "$PRD_MODEL" 2400 "$IDIR/prd.out.txt" "$PRD_PROMPT"
if [ ! -s "$IDIR/ticket.html" ] || [ ! -s "$IDIR/prd.md" ]; then
  echo "$(STAMP) [$PROJECT] draft: PRD stage failed for $SLUG" >> "$ALERTS"; exit 1
fi

MOCKUP_PROMPT="Mockup stage for a client feature proposal. Idea (JSON): $IDEA
PRD: read $IDIR/prd.md.
Theme: harvest the REAL design tokens from $REPO (globals.css / tailwind config / an existing page's classes) — colors, fonts, radii, spacing, sidebar/nav chrome — so the mockup looks native to this exact app.
Write ONE file: $IDIR/mockup.html — a fully self-contained static mockup of the feature's primary screen(s):
- Inline CSS only, no external assets, no JavaScript beyond trivial tab/section toggling.
- Realistic FAKE data (plausible names/numbers for this client's domain, nothing real).
- Responsive: perfect at 1280px AND 375px, no horizontal body scroll; tables scroll inside their own container.
- Obey the UI iron laws it depicts: sortable-header affordances, rows that look clickable, drill-down cues.
- A slim fixed banner at the very top: 'MOCKUP — proposed feature, not live' (subtle, not garish).
- If the feature has 2-3 key screens, include them as sections with a simple tab/anchor nav.
Do not modify any repo files. Final line: MOCKUP_DONE or MOCKUP_FAILED <reason>."
"$HARNESS/bin/agent-call.sh" mockup "$PROJECT" "$MOCKUP_MODEL" 2400 "$IDIR/mockup.out.txt" "$MOCKUP_PROMPT"
if [ ! -s "$IDIR/mockup.html" ]; then
  echo "$(STAMP) [$PROJECT] draft: mockup stage failed for $SLUG" >> "$ALERTS"; exit 1
fi

"$HARNESS/bin/mockup-shot.sh" "$IDIR" 2>>"$ALERTS" || true
"$HARNESS/bin/push-proposal-assets.sh" "prop:$PROJECT:$SLUG" "$IDIR" 2>>"$ALERTS" || true
exit 0
