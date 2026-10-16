#!/bin/bash
# bin/inbuild-lead-review.sh <project> <owner/repo> <pr> <sha> <build-dir> —
# BH-5023 (BH-4973.2): the lead-grade review of a MEDIUM risk PR, run inside the
# build that pushed it, while its context is warm. Called once by the
# `# >>> inbuild lead review` block of bin/run-build.sh, after rb_settle, only
# when the build settled APPROVE and a PR exists; <sha> is the head it settled
# on. KEY (env) is the ticket key, for requested_by.
#
# A build box has the bearer and never the lead token, so it cannot publish a
# lead-verdict itself. It goes the lead lane's own way: file a lead_review_requests
# row for THIS head, review it with `bin/lead-review.sh one <id>` (review_one:
# the same prompts/lead-review.md + checklist, model_for lead.review, rules pack,
# host suite, paid-once ledger and result post), and the hub's
# bin/lead-review-land.sh promotes the result into the source=lead row and the
# lead-verdict status, after checking a builder APPROVE is bound to that head.
#
# In order, each step a no-op exit 0 when it cannot go on:
#   mode     rt_mode (bin/lib/risk-tier.sh): off = nothing; shadow = classify
#            and log `WOULD review in-build`, no request, no model call.
#   head     gh_rest GET pulls/<pr>: unreadable, or not <sha> = nothing. A sha
#            that is not live is never asked about.
#   tier     ONE compare read, rt_classify. Unreadable = nothing (the hub's
#            grace runs out and the lead lane reviews it). low/high = nothing:
#            low is wave 1's sign-off, high is the lead lane's.
#   request  medium + enforce: POST /api/lead-reviews (bearer only; the worker
#            allows requested_by inbuild:<box>:<KEY>, no priority). 201,
#            existing:true, or a 409 carrying the row = that row. A row that is
#            not `requested` is someone else's review already: nothing.
#   review   bin/lead-review.sh one <id>, true rc, unpiped.
# Writes $BUILD/inbuild-lead-review.txt (mode, tier, reasons, result, request,
# rc, verdict) and one pipeline.log line. Never fails the build: rc 0 on every
# no-op, the review's rc when it ran, 2 on bad arguments.
set -uo pipefail
[ "$#" -eq 5 ] || { echo "usage: bin/inbuild-lead-review.sh <project> <owner/repo> <pr> <sha> <build-dir>" >&2; exit 2; }
PROJECT="$1" SLUG="$2" PRN="$3" SHA="$4" BUILD="$5"
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

[ -d "$BUILD" ] || { echo "inbuild-lead-review: no build dir $BUILD" >&2; exit 2; }
OUT="$BUILD/inbuild-lead-review.txt"
MODE=""; TIER=""; WHY=""; RESULT=""; ID=""; ORC=""; VERDICT=""
finish() { # finish <result> [rc] — the record, one pipeline.log line, exit
  RESULT="$1"
  printf 'mode=%s\ntier=%s\nreasons=%s\nresult=%s\nrequest=%s\nrc=%s\nverdict=%s\n' \
    "$MODE" "$TIER" "$WHY" "$RESULT" "$ID" "$ORC" "$VERDICT" > "$OUT" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT/${KEY:-?}] inbuild lead review ${SHA:0:12}: $RESULT${TIER:+ (tier $TIER)}${ID:+ request $ID}${ORC:+ rc $ORC}${VERDICT:+ verdict $VERDICT}" >> "$BUILD/pipeline.log"
  exit "${2:-0}"
}
[[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$PRN" =~ ^[0-9]+$ && "$SHA" =~ ^[0-9a-f]{40}$ ]] \
  || finish "bad arguments (repo '$SLUG', pr '$PRN', sha '$SHA')"

# jobs-client.sh exits its caller on a missing module, so every piece is checked first.
for f in bin/jobs-client.sh bin/lib/jobs/req.sh bin/lib/lead-reviews.sh bin/lib/gh-rest.sh \
         bin/lib/risk-tier.sh bin/lib/hub-box.sh bin/lead-review.sh; do
  [ -r "$H/$f" ] || finish "missing $f"
done
# shellcheck source=/dev/null
{ . "$H/bin/jobs-client.sh"; . "$H/bin/lib/lead-reviews.sh"; . "$H/bin/lib/gh-rest.sh"
  . "$H/bin/lib/risk-tier.sh"; . "$H/bin/lib/hub-box.sh"; }

IFS=$'\t' read -r MODE MWHY < <(rt_mode "$SLUG")
[ "$MODE" = off ] && finish "risk tier off${MWHY:+ ($MWHY)}"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/inbuild-lead-review.XXXXXX") || finish "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
# To files, not $( ): GH_REST_STATUS lives in this shell only.
grc=0; gh_rest GET "repos/$SLUG/pulls/$PRN" > "$WORK/pr" 2>/dev/null || grc=$?
LIVE=$(jq -r '.head.sha // empty' "$WORK/pr" 2>/dev/null | tr 'A-F' 'a-f')
BASE=$(jq -r '.base.ref // "main"' "$WORK/pr" 2>/dev/null)
[ "$grc" = 0 ] && [ -n "$LIVE" ] || finish "head unreadable (HTTP ${GH_REST_STATUS:-000})"
[ "$LIVE" = "$SHA" ] || finish head-moved
grc=0; gh_rest GET "repos/$SLUG/compare/$(jq -rn --arg b "$BASE" '$b|@uri')...$SHA" > "$WORK/cmp" 2>/dev/null || grc=$?
[ "$grc" = 0 ] || finish "compare unreadable (HTTP ${GH_REST_STATUS:-000})"
IFS=$'\t' read -r TIER WHY _ _ < <(rt_classify "$WORK/cmp" "$SLUG")
case "$TIER" in
  low|high) finish "not medium" ;;
  medium) ;;
  *) TIER=""; finish "tier unreadable" ;;
esac
[ "$MODE" = shadow ] && finish "WOULD review in-build (shadow)"

BOX=$(printf '%s' "${JOBS_BOX:-$(local_box_name)}" | tr -cd 'A-Za-z0-9._-'); BOX="${BOX:-unknown}"
K=$(printf '%s' "${KEY:-}" | tr -cd 'A-Za-z0-9._-'); K="${K:-build}"
# BH-6967: $WHY names diff paths; the review tier and mode words in it are
# rewritten, so a path never reads as the tokens bin/lead-review.sh trusts.
WHY="${WHY//review-tier:/review-tier=}"; WHY="${WHY//review-mode:/review-mode=}"
BODY=$(jq -nc --arg r "$SLUG" --argjson p "$PRN" --arg h "$SHA" --arg by "inbuild:$BOX:$K" \
  --arg n "inbuild: builder APPROVE on ${SHA:0:12}, risk tier medium ($WHY)" \
  '{repo:$r, pr:$p, head_sha:$h, requested_by:$by, scope_notes:($n | .[0:4000])}')
prc=0; RESP=$(lr_post '' "$BODY" 2>"$WORK/err") || prc=$?
ID=$(jq -r '.request.id // empty' <<<"$RESP" 2>/dev/null)
ST=$(jq -r '.request.status // empty' <<<"$RESP" 2>/dev/null)
RSHA=$(jq -r '.request.head_sha // empty' <<<"$RESP" 2>/dev/null)
if [ "$prc" != 0 ] && ! { grep -q 'HTTP 409' "$WORK/err" && [ -n "$ID" ]; }; then
  ID=""; finish "request not filed ($(tr '\n' ' ' < "$WORK/err")$(printf '%s' "$RESP" | tr '\n' ' ' | head -c 200))"
fi
[ -n "$ID" ] && [ "$RSHA" = "$SHA" ] || { ID=""; finish "request answer names no row for this head"; }
[ "$ST" = requested ] || finish "already $ST"

ORC=0; "$H/bin/lead-review.sh" one "$ID" </dev/null >/dev/null 2>&1 || ORC=$?
VERDICT=$(lr_get "/$ID" 2>/dev/null | jq -r '.request | if .verdict then .verdict else "none (" + (.status // "?") + ")" end' 2>/dev/null)
finish "reviewed" "$ORC"
