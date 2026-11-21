#!/bin/bash
# tests/release-model.bh-9862-test.sh — a project whose merges deploy to
# STAGING (catalog/release-model.tsv) is never treated as live because a PR
# merged, and a project with no row behaves as it did before the file existed.
#
#   L1-L7  bin/lib/release-model.sh: the default, the row, the refusals, apply
#   C1-C4  the real bin/board-closeout.sh against a stub board:
#          staging + PR_CREATED  comment, staging link, move to in_progress
#          staging + PR_MERGED   "on staging", "not live on production", review
#          no row  + PR_CREATED  move to review, production link (unchanged)
#          no row  + PR_MERGED   move to done (unchanged)
#   M1-M2  the real bin/migration-autopilot.sh: a staging project stops before
#          any request; a project with no row still reaches its own wiring
#   O1-O4  the three lanes that read a deploy apply the model BELOW their env
#          load, and the merged-ticket comment keeps the words its dedupe reads
#   B1     no request left the stub hosts
#
# Run from anywhere: tests/release-model.bh-9862-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

row() { printf '%s\t%s\t%s\t%s\n' "$@"; }

# ══ L — the library ═══════════════════════════════════════════════════════
LH="$T/l"; mkdir -p "$LH/catalog"
lib() { ( export HARNESS="$LH"; unset RELEASE_MODEL_FILE; . "$DIR/bin/lib/release-model.sh"; "$@" ); }
[ "$(RELEASE_MODEL_FILE="$T/absent.tsv" HARNESS="$T/none" bash -c 'cd / && . "$1/bin/lib/release-model.sh"; _release_model_file() { return 1; }; release_model stg' _ "$DIR")" = production ] && ok \
  || bad "L1 no catalog file must read production"
{ echo "# a comment"; echo; row stg staging https://stg.example.test/ https://stg.example.test/api/internal/version
  row odd canary https://odd.example.test https://odd.example.test/v
  row bare staging stg.example.test -
  row nover staging https://nover.example.test -
  row shift staging "" https://shift.example.test/v; } > "$LH/catalog/release-model.tsv"
[ "$(lib release_model stg)" = staging ] && ok || bad "L2 a staging row must read staging (got '$(lib release_model stg)')"
[ "$(lib release_model other)" = production ] && ok || bad "L3 no row must read production"
[ "$(lib release_model odd)" = production ] && ok || bad "L4 an unknown model must read production"
[ "$(lib release_model bare)" = production ] && ok || bad "L5 a staging row with no https base must read production"
[ "$(lib release_model shift)" = production ] && ok || bad "L5 an EMPTY base column must not take the next column's value"
[ "$(lib release_staging_base stg)" = "https://stg.example.test" ] && [ -z "$(lib release_staging_base other)" ] && ok \
  || bad "L6 the staging base loses its trailing slash, and is empty with no row"
[ "$(lib release_staging_version_url nover)" = "https://nover.example.test/api/internal/version" ] && ok \
  || bad "L6 a row with no version address gets the default route on its base"
OUT=$(lib bash -c 'VERSION_URL=https://prod/v VERSION_AUTH=secret DEPLOY_HOOK_URL=https://hook DEPLOY_ROLLBACK=on
  . "$0/bin/lib/release-model.sh"; release_model_apply stg
  echo "$VERSION_URL|$DEPLOY_ROLLBACK|${VERSION_AUTH-unset}|${DEPLOY_HOOK_URL-unset}|${RELEASE_MODEL:-}|${RELEASE_STAGING_BASE:-}"' "$DIR")
[ "$OUT" = "https://stg.example.test/api/internal/version|off|unset|unset|staging|https://stg.example.test" ] && ok \
  || bad "L7 apply must point the reads at staging, turn rollback off and drop the production token and hook (got '$OUT')"
OUT=$(lib bash -c 'VERSION_URL=https://prod/v VERSION_AUTH=secret DEPLOY_HOOK_URL=https://hook DEPLOY_ROLLBACK=on
  . "$0/bin/lib/release-model.sh"; release_model_apply other
  echo "$VERSION_URL|$DEPLOY_ROLLBACK|${VERSION_AUTH-unset}|${DEPLOY_HOOK_URL-unset}|${RELEASE_MODEL:-}|${RELEASE_STAGING_BASE:-}"' "$DIR")
[ "$OUT" = "https://prod/v|on|secret|https://hook||" ] && ok || bad "L7 apply must change nothing for a project with no row (got '$OUT')"

# ══ the stub board ════════════════════════════════════════════════════════
FB="$T/fakebin"; mkdir -p "$FB"
cat > "$FB/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""
for a in "$@"; do [ "${prev:-}" = -d ] && BODY="$a"; prev="$a"; done
printf '%s\n' "$URL" >> "$CURL_LOG"
case "$URL" in
  https://app.example.test/*/comments) printf '%s\n' "$BODY" >> "$CURL_LOG.bodies"; echo '{"comment":{"id":"c1"}}' ;;
  https://app.example.test/*/move)     printf '%s\n' "$BODY" >> "$CURL_LOG.moves"
                                       printf '{"ticket":{"status":"%s"}}\n' "$(printf '%s' "$BODY" | jq -r .toStatus)" ;;
  *) exit 7 ;;
esac
STUB
chmod +x "$FB/curl"

# ══ C — the real bin/board-closeout.sh ════════════════════════════════════
CH="$T/c/h"; mkdir -p "$CH/state" "$CH/flags" "$CH/env" "$CH/catalog" "$CH/builds/b1"
scratch_install_closure bin/board-closeout.sh "$CH" >/dev/null || bad "C setup: cannot install the close-out closure"
[ -f "$CH/bin/lib/release-model.sh" ] || bad "C setup: bin/board-closeout.sh must source bin/lib/release-model.sh"
cat > "$CH/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in prod) echo "https://app.example.test" ;; board_prefix) echo "/api/board" ;; *) exit 1 ;; esac
SH
printf '#!/bin/bash\necho tok-fixture-board\n' > "$CH/bin/internal-token-for.sh"
printf '#!/bin/bash\necho OK\n' > "$CH/bin/triage-gate.sh"
chmod +x "$CH/bin/fleet-conf.sh" "$CH/bin/internal-token-for.sh" "$CH/bin/triage-gate.sh"
row stg staging https://stg.example.test https://stg.example.test/api/internal/version > "$CH/catalog/release-model.tsv"
BB="$CH/builds/b1"
printf '## QA screens\n- /clients — the list\n\n## Size\n' > "$BB/plan.md"
closeout() { # closeout <project> <RESULT line>
  : > "$T/c.curl"; : > "$T/c.curl.bodies"; : > "$T/c.curl.moves"; echo "$2" > "$BB/RESULT"
  OUT=$(env PATH="$FB:$PATH" HARNESS="$CH" CURL_LOG="$T/c.curl" BUILDER_DIRECT=1 \
          "$CH/bin/board-closeout.sh" "$1" T1 TK-9 "$BB" 2>"$T/c.err"); RC=$?
}
closeout stg "PR_CREATED https://github.com/o/r/pull/8"
[ "$RC" = 0 ] && grep -q 'tickets/T1/comments' "$T/c.curl" && ok || bad "C1 staging + PR_CREATED must post the comment (rc $RC; $(tail -2 "$T/c.err"))"
# BH-9870: the merge lane (bin/merged-ticket-advance.sh) takes a ticket only in
# in_progress or review. A ticket left in todo at PR open is never advanced.
[ "$(jq -r .toStatus "$T/c.curl.moves" 2>/dev/null)" = in_progress ] && ok \
  || bad "C1 staging + PR_CREATED must move the ticket to in_progress, never review (got $(cat "$T/c.curl.moves"))"
grep -q 'stg.example.test/clients' "$T/c.curl.bodies" && grep -q 'after this merges' "$T/c.curl.bodies" && ok \
  || bad "C1 the comment must link staging and say the link works after the merge"
grep -q 'app.example.test/clients' "$T/c.curl.bodies" && bad "C1 the comment must not link production" || ok
case "$OUT" in "POSTED stg/TK-9 -> in_progress"*) ok ;; *) bad "C1 stdout must name the move to in_progress (got '$OUT')" ;; esac

closeout stg "PR_MERGED https://github.com/o/r/pull/8"
[ "$RC" = 0 ] && grep -q 'merged and on its way to staging' "$T/c.curl.bodies" && grep -q 'not live on production yet' "$T/c.curl.bodies" && ok \
  || bad "C2 staging + PR_MERGED must say on staging and not live (rc $RC; $(cat "$T/c.curl.bodies"))"
grep -q 'on its way to production' "$T/c.curl.bodies" && bad "C2 a staging merge must not say it is on its way to production" || ok
[ "$(jq -r .toStatus "$T/c.curl.moves" 2>/dev/null)" = review ] && ok || bad "C2 a staging merge moves the ticket to review, never done (got $(cat "$T/c.curl.moves"))"
grep -q 'stg.example.test/clients' "$T/c.curl.bodies" && ok || bad "C2 the comment must link staging"

closeout ctl "PR_CREATED https://github.com/o/r/pull/9"
[ "$RC" = 0 ] && [ "$(jq -r .toStatus "$T/c.curl.moves" 2>/dev/null)" = review ] && grep -q 'app.example.test/clients' "$T/c.curl.bodies" && ok \
  || bad "C3 no row + PR_CREATED is unchanged: review, production link (rc $RC; $(cat "$T/c.curl.moves"))"
grep -q 'staging' "$T/c.curl.bodies" && bad "C3 a project with no row must not mention staging" || ok
closeout ctl "PR_MERGED https://github.com/o/r/pull/9"
[ "$RC" = 0 ] && [ "$(jq -r .toStatus "$T/c.curl.moves" 2>/dev/null)" = done ] && grep -q 'on its way to production' "$T/c.curl.bodies" && ok \
  || bad "C4 no row + PR_MERGED is unchanged: done (rc $RC; $(cat "$T/c.curl.moves"))"

# BH-9873: a SLICE build at PR open on a staging project also goes to
# in_progress, with the slice named in the output.
printf '## QA screens\n- /clients — the list\n\nSLICE: C2 of #TK-9\n\n## Size\n' > "$BB/plan.md"
closeout stg "PR_CREATED https://github.com/o/r/pull/8"
[ "$RC" = 0 ] && [ "$(jq -r .toStatus "$T/c.curl.moves" 2>/dev/null)" = in_progress ] && ok \
  || bad "C5 staging + slice + PR_CREATED must move the ticket to in_progress (rc $RC; got $(cat "$T/c.curl.moves"); $(tail -2 "$T/c.err"))"
case "$OUT" in "POSTED stg/TK-9 -> in_progress (slice C2"*) ok ;; *) bad "C5 stdout must name the slice and in_progress (got '$OUT')" ;; esac
printf '## QA screens\n- /clients — the list\n\n## Size\n' > "$BB/plan.md"

# ══ M — the real bin/migration-autopilot.sh ═══════════════════════════════
MH="$T/m/h"; mkdir -p "$MH/state" "$MH/flags" "$MH/env" "$MH/logs" "$MH/locks" "$MH/catalog"
scratch_install_closure bin/migration-autopilot.sh "$MH" >/dev/null || bad "M setup: cannot install the autopilot closure"
row stg staging https://stg.example.test https://stg.example.test/api/internal/version > "$MH/catalog/release-model.tsv"
: > "$MH/env/global.env"
autopilot() { : > "$T/m.curl"; env -u JOBS_URL -u HARNESS_JOBS_URL PATH="$FB:$PATH" HARNESS="$MH" CURL_LOG="$T/m.curl" \
                bash "$MH/bin/migration-autopilot.sh" "$1" >/dev/null 2>"$T/m.err"; }
autopilot stg; RC=$?
[ "$RC" = 0 ] && [ ! -s "$MH/logs/stg.log" ] && [ ! -s "$T/m.curl" ] && ok \
  || bad "M1 a staging project stops with rc 0, no log line and no request (rc $RC; log: $(cat "$MH/logs/stg.log" 2>/dev/null); curl: $(cat "$T/m.curl"))"
autopilot ctl; RC=$?
[ "$RC" = 0 ] && grep -q 'no migration endpoint wiring for ctl' "$MH/logs/ctl.log" 2>/dev/null && ok \
  || bad "M2 a project with no row must still reach its own wiring check (rc $RC; $(tail -2 "$T/m.err"))"

# ══ P — the lanes that would act on production ═══════════════════════════
grep -q '^  if \[ -n "\$STG_BASE" \]; then' "$DIR/bin/postmerge-qa.sh" \
  && [ "$(grep -n '^  if \[ -n "\$STG_BASE" \]; then' "$DIR/bin/postmerge-qa.sh" | head -1 | cut -d: -f1)" -lt \
       "$(grep -n -- '--- the account ---' "$DIR/bin/postmerge-qa.sh" | head -1 | cut -d: -f1)" ] && ok \
  || bad "P1 bin/postmerge-qa.sh must stop a staging project before it touches the QA account"
grep -q '\[ "\$SITE" = staging \] && exit 0' "$DIR/bin/deploy-train.sh" && ok || bad "P2 bin/deploy-train.sh must not run the production migration driver for a staging project"
grep -q 'DEPLOY TRAIN: production is NOT serving' "$DIR/bin/deploy-train.sh" && bad "P3 the deploy train alert must name the site it checked" || ok
grep -q 'STAGING_BASE" \] && command -v prod_red_defers_dir' "$DIR/bin/board-closeout.sh" && ok || bad "P4 the production-red defer must not hold a staging close-out"

# ══ O — order and words in the lanes that read a deploy ═══════════════════
below() { # below <file> <env-load pattern> — the apply call sits under the LAST env load
  local f="$DIR/$1" e a
  e=$(grep -nE "$2" "$f" | tail -1 | cut -d: -f1); a=$(grep -n 'release_model_apply "\$' "$f" | head -1 | cut -d: -f1)
  [ -n "$e" ] && [ -n "$a" ] && [ "$a" -gt "$e" ]
}
below bin/deploy-train.sh          '^set -a; \. "\$HENV/global.env"' && ok || bad "O1 bin/deploy-train.sh must apply the model below its env load"
below bin/postmerge-qa.sh          '^set -a; \. "\$HENV/global.env"' && ok || bad "O2 bin/postmerge-qa.sh must apply the model below its env load"
below bin/merged-ticket-advance.sh '^\. "\$HENV/\$PROJECT.env"'      && ok || bad "O3 bin/merged-ticket-advance.sh must apply the model below its env load"
a=$(grep -n 'release_model_apply "\$PROJECT"' "$DIR/bin/deploy-train.sh" | head -1 | cut -d: -f1)
g=$(grep -n '^\[ -n "\${VERSION_URL:-}" \] || exit 0' "$DIR/bin/deploy-train.sh" | head -1 | cut -d: -f1)
[ -n "$a" ] && [ -n "$g" ] && [ "$a" -lt "$g" ] && ok || bad "O1 bin/deploy-train.sh must apply the model above its VERSION_URL gate"
N=$(grep -c 'body="<p>This is merged and on staging\|body="<p>This is merged and in main' "$DIR/bin/merged-ticket-advance.sh")
[ "$N" -ge 3 ] && ok || bad "O4 each staging comment of bin/merged-ticket-advance.sh must start with the words its dedupe reads (found $N)"
grep -q '^\[ -n "\$STG_BASE" \] && PROD="\$STG_BASE"' "$DIR/bin/postmerge-qa.sh" && ok \
  || bad "O2 bin/postmerge-qa.sh must drive the staging site for a staging project"

# BH-9873: the words a staging project must not get, and the guard on the row.
grep -q 'WHERE=live; \[ "\$SITE" = staging \] && WHERE="on staging"' "$DIR/bin/deploy-train.sh" \
  && [ "$(grep -c 'VERIFIED \$WHERE at' "$DIR/bin/deploy-train.sh")" = 2 ] && ! grep -q 'VERIFIED live' "$DIR/bin/deploy-train.sh" && ok \
  || bad "O5 bin/deploy-train.sh must say VERIFIED on staging for a staging project, in the log and in the queue row"
grep -q 'local _d; _d=\$(jq -c .\. + {target:"staging"}. <<<"\$detail" 2>/dev/null) && \[ -n "\$_d" \] && detail=\$_d' "$DIR/bin/deploy-train.sh" && ok \
  || bad "O6 a failed jq must not empty the ledger detail of bin/deploy-train.sh"
grep -q 'SITE_W=staging; QA_W=STAGING; SEEN_W="on staging"' "$DIR/bin/postmerge-qa.sh" \
  && grep -q 'POST-MERGE \$QA_W QA NOT RUN' "$DIR/bin/postmerge-qa.sh" && ! grep -q 'POST-MERGE PROD QA NOT RUN' "$DIR/bin/postmerge-qa.sh" && ok \
  || bad "O7 the deploy-timeout alert of bin/postmerge-qa.sh must name staging for a staging project"
grep -q 'release_is_staging "\$PROJECT"' "$DIR/bin/check-migration-prs.sh" \
  && grep -q -- '— \$MIG_ASK (\$TITLE)' "$DIR/bin/check-migration-prs.sh" && grep -q -- '— \$MIG_LOG" >>' "$DIR/bin/check-migration-prs.sh" \
  && grep -q 'MIG_LOG="confirm SQL applied to prod"; MIG_ASK="confirm it is applied to prod"' "$DIR/bin/check-migration-prs.sh" && ok \
  || bad "O8 bin/check-migration-prs.sh must not ask for a production apply right after a staging merge"

# ══ B — nothing left the stubs ════════════════════════════════════════════
# Read the stub logs first, then match (BH-1818): a pipe into grep -q can pass
# in the case this check exists to catch.
REQS=$(cat "$T/c.curl" "$T/m.curl" 2>/dev/null || true)
{ [ -n "$REQS" ] && grep -qv '^https://app.example.test/' <<<"$REQS"; } && bad "B1 a request reached a host other than the board stub" || ok

echo "release-model.bh-9862-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
