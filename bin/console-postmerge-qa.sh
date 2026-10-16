#!/bin/bash
# bin/console-postmerge-qa.sh <console-ui sha> <kept dist dir> — browser QA of
# a console-ui commit AFTER it shipped to Cloudflare Pages production (BH-5909
# slice 3). Launched DETACHED by bin/console-pages-deploy.sh after its probes,
# only when CONSOLE_POSTMERGE_QA=1; never run by cron. Output goes to stdout,
# which that launch sends to logs/console-postmerge-qa.log.
#
# WHY. The preview lane (bin/console-preview-deploy.sh) drives a PR head before
# merge. Nothing loaded the console that actually shipped, at the widths the
# ticket names, after the merge.
#
# WHY AN ALIAS, NOT THE PRODUCTION HOST. console-ui/functions/qa-login refuses
# the production host, every <8 hex> deployment URL and the main alias, so the
# read-only QA session never signs in on production. This run deploys the SAME
# shipped bytes once more, to the fixed alias `postmerge-qa`: the dist/ that
# console-pages-deploy.sh uploaded (it keeps a copy at
# state/console-postmerge-qa/dist-<sha>), and the functions/ and src/ of the
# same commit. cpv_alias reserves the alias, so no PR branch deploys over it.
# An alias runs in the Pages PREVIEW environment, as slice 1's preview QA does;
# the PR comment says so.
#
# STEPS. The knob (env, then the settings row, default 0); flock -n (dedupe,
# never a queue); state/console-postmerge-qa/<sha>/verdict already there: stop
# before any network call. Then the deploy tree, the upload (pinned wrangler,
# CONSOLE_PREVIEW_WRANGLER, --branch postmerge-qa, never main), the QA session
# (POST /api/qa/session, cromford-console #46), and bin/console-qa-run.mjs
# at CONSOLE_QA_WIDTHS=1280,375 over CONSOLE_POSTMERGE_QA_SCREENS.
#
# THE VERDICT, one line in state/console-postmerge-qa/<sha>/verdict:
#   PASS                  the driver exited 0, printed `QA: PASS`, and its
#                         QA COVERAGE has screens and shots of 1 or more
#   FAIL                  the driver observed at least one screen, and not PASS
#   NOT_COVERED <reason>  nothing was observed: the tree, the upload, the mint
#                         or the drive did not get as far as a screen
# Verdict first, then ONE comment on the merged PR (marker
# `<!-- console-postmerge-qa sha=<sha> result=<r> -->`, never posted twice),
# then the alert under fleet-propagate: FAIL raises console-postmerge-qa,
# NOT_COVERED raises console-postmerge-qa-notcovered, PASS resolves both, and a
# rejected POST raises console-postmerge-qa-post. The comment never has a line
# that starts `QA: PASS` or `QA: FAIL`: bin/lib/console-qa-gate.sh reads those
# lines on open PRs.
#
# GROUPED FINDINGS (BH-6902). A FAIL, after the comment and before the alert,
# turns the driver's observed.json into findings (gf_from_observed) and hands
# them to gf_run of bin/lib/group-findings.sh under the board cromford: one
# issue per screen on HARNESS_REPO, or a comment on the open issue of that
# screen. Off until the settings row lib.group-findings.cromford.
# group_findings is 1; off, the ledger rows say `off` and nothing is filed. The
# ledger (qa-findings.jsonl, findings-ledger.jsonl, group-findings.md) lives in
# state/console-postmerge-qa/<sha>/ and follows its 14-day prune. Fail-open: it
# never changes the verdict, the comment or the exit; a failed or deferred
# filing, or an unreadable observed.json, is appended to the FAIL alert.
#
# Secrets: the Cloudflare token and HARNESS_SECRET live only in subshell envs,
# the QA token only in the driver's env; all three are scrubbed from the log,
# qa.md and the comment. Every stop is exit 0.
set -uo pipefail
H="${HARNESS:-/root/harness}"
CO="${HARNESS_CHECKOUT:-/root/harness-checkout}"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }; HENV=$(harness_env_dir "$H")
CFENV="$HENV/cloudflare.env"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
JC="$H/bin/jobs-client.sh"
LA="$H/bin/lane-alert.sh"
QD="$H/state/console-postmerge-qa"
ALIAS=postmerge-qa
log() { echo "$(STAMP) console-postmerge-qa: $*"; }
alert() { [ -x "$LA" ] && "$LA" "$@" fleet-propagate "${ALERT_MSG:-}" >/dev/null 2>&1 || true; }

# Not the hub: silent.
[ -f "$CFENV" ] && [ -e "$CO/.git" ] || exit 0

CSHA="${1:-}"; DIST="${2:-}"
[[ "$CSHA" =~ ^[0-9a-f]{40}$ ]] || { log "refused: '$CSHA' is not a 40-hex console-ui sha"; exit 0; }
C7=${CSHA:0:7}
# Only the copy console-pages-deploy.sh keeps for this sha is ever uploaded.
[ "$DIST" = "$QD/dist-$CSHA" ] && [ -d "$DIST" ] && [ ! -L "$DIST" ] \
  || { log "refused: '$DIST' is not $QD/dist-$CSHA"; exit 0; }

# pq_knob <ENV> <default> [str] — the env, then lane.fleet-propagate.<env> in
# settings, then the default. An int knob reads only digits; a value that is
# not one falls through, never clamps.
pq_knob() {
  local v="${!1:-}" str="${3:-}"
  [ -n "$str" ] || case "$v" in *[!0-9]*) v="" ;; esac
  if [ -z "$v" ] && [ -x "$JC" ]; then
    v=$("$JC" setting-get "lane.fleet-propagate.$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" 2>/dev/null)
    if [ -n "$str" ]; then v=$(printf '%s' "$v" | tr -s '[:space:]' ' '); v=${v# }; v=${v% }
    else v=$(printf '%s' "$v" | tr -d '[:space:]'); case "$v" in *[!0-9]*) v="" ;; esac; fi
  fi
  printf '%s\n' "${v:-$2}"
}
rm_dist() { case "$DIST" in "$QD/dist-"?*) rm -rf -- "$DIST" ;; esac; }

ON=$(pq_knob CONSOLE_POSTMERGE_QA 0)
[ "$ON" = 1 ] || { log "CONSOLE_POSTMERGE_QA=$ON — off; the kept dist of $C7 is removed"; rm_dist; exit 0; }

mkdir -p "$QD" "$H/locks" || exit 0
exec 5>"$H/locks/console-postmerge-qa.lock"
# Dedupe, never a queue. The kept dist stays; the prune of a later run removes it.
flock -n 5 || { log "another post-merge QA run holds the lock — $C7 not driven"; exit 0; }
OUT="$QD/$CSHA"
if [ -e "$OUT/verdict" ]; then
  log "$C7 already has a verdict ($(head -n 1 "$OUT/verdict")) — not driven again"; rm_dist; exit 0
fi

TREE=""
cleanup() {
  case "$TREE" in "$H/state/console-postmerge-snap."?*) rm -rf -- "$TREE" ;; esac
  rm_dist
  find "$QD" -mindepth 1 -maxdepth 1 -type d -name 'dist-*' -mmin +1440 -exec rm -rf -- {} + 2>/dev/null
  find "$QD" -mindepth 1 -maxdepth 1 -type d -mtime +14 -regextype posix-extended -regex '.*/[0-9a-f]{40}' -exec rm -rf -- {} + 2>/dev/null
}
trap cleanup EXIT
trap 'exit 143' TERM INT
# A run the timeout killed can leave its tree; the lock says none is live.
for old in "$H"/state/console-postmerge-snap.*; do
  case "$old" in "$H/state/console-postmerge-snap."?*) [ -d "$old" ] && rm -rf -- "$old" ;; esac
done

. "$H/bin/lib/console-preview.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/console-preview.sh" 2>/dev/null \
  || { log "bin/lib/console-preview.sh missing — $C7 not driven"; exit 0; }
. "${HARNESS_DEPLOYMENT_FILE-$H/bin/lib/deployment.sh}" 2>/dev/null || true
SLUG="${HARNESS_REPO:-}"
WRANGLER="${CONSOLE_PREVIEW_WRANGLER:-3.114.17}"
[[ "$WRANGLER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { log "CONSOLE_PREVIEW_WRANGLER='$WRANGLER' is not an exact version — using 3.114.17"; WRANGLER=3.114.17; }
SCREENS=$(pq_knob CONSOLE_POSTMERGE_QA_SCREENS '/ /now /kanban /jobs /t/BH-5909 /machines /lead-reviews' str)
URL=$(cpv_url "$ALIAS") || URL=""
mkdir -p "$OUT"
log "start $C7"

scrub() { # scrub <file> <secret>... — the file with each secret and any Bearer value replaced
  local f="$1"; shift
  S="$(printf '%s\n' "$@")" awk 'BEGIN{n=split(ENVIRON["S"],t,"\n")} {for (k=1;k<=n;k++) if (t[k]!="") while ((i=index($0,t[k]))>0) $0=substr($0,1,i-1) "***" substr($0,i+length(t[k])); gsub(/Bearer[ \t]+[^ \t]+/,"Bearer ***"); print}' "$f"
}

# report <verdict> — verdict file, then the comment, then the alert; exit 0.
report() {
  local v="$1" res pr rc=0 first
  printf '%s\n' "$v" > "$OUT/verdict"
  log "verdict $v at $C7"
  res=${v%% *}
  {
    printf 'Console post-merge QA for %s: %s.\n\n' "$C7" "$( [ "$res" = NOT_COVERED ] && echo 'NOT COVERED' || echo "$res")"
    if [ "$res" = NOT_COVERED ]; then
      printf 'No screen of %s was observed.\n' "${URL:-the postmerge-qa alias}"
    else
      printf 'Drove %s at 1280px and 375px, signed in as the read-only QA session (loads only, no clicks).\n' "$URL"
    fi
    printf 'This is the shipped dist/ and Functions of %s, deployed to the %s alias, because the read-only QA session never signs in on the production host. The alias runs in the Pages preview environment.\n\n' "$C7" "$ALIAS"
    [ "$res" = NOT_COVERED ] && printf 'Reason: %s\n\n' "${v#NOT_COVERED }"
    if [ -s "$OUT/qa.md" ]; then
      printf '```\n'; grep -E '^(FAIL: |SCREEN |QA COVERAGE: )' "$OUT/qa.md" | head -60; printf '```\n\n'
    fi
    printf 'POST-MERGE QA: %s at %s\n' "$res" "$CSHA"
    printf '<!-- console-postmerge-qa sha=%s result=%s -->\n' "$CSHA" "$res"
  } > "$OUT/comment.md"

  if [ -z "$SLUG" ]; then
    log "HARNESS_REPO unset — comment NOT posted"
  else
    gh_rest GET "repos/$SLUG/commits/$CSHA/pulls" > "$OUT/pulls.json" 2>/dev/null || rc=$?
    case "$rc" in
      0) pr=$(jq -r --arg s "$CSHA" '([.[]? | select(.merge_commit_sha == $s)] + [.[]? | select(.merged_at != null)]) | .[0].number // empty' "$OUT/pulls.json" 2>/dev/null)
         if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
           log "no merged PR for $C7 — comment NOT posted"
         else
           rc=0; cpv_comments "$SLUG" "$pr" "$OUT/thread.json" || rc=$?
           if [ "$rc" != 0 ]; then
             log "PR #$pr comments unreadable (rc=$rc HTTP ${GH_REST_STATUS:-000}) — comment NOT posted"
           elif jq -e --arg m "<!-- console-postmerge-qa sha=$CSHA " 'any(.[]?; (.body // "") | contains($m))' "$OUT/thread.json" >/dev/null 2>&1; then
             log "PR #$pr already has the post-merge QA comment for $C7 — not posted again"
           elif gh_rest_comment "$SLUG" "$pr" "$OUT/comment.md"; then
             log "comment posted on PR #$pr"
           else
             log "comment on PR #$pr rejected (HTTP ${GH_REST_STATUS:-000}) — NOT posted; the body is $OUT/comment.md"
             ALERT_MSG="[$(hostname)] GitHub rejected the console post-merge QA comment for $C7 on PR #$pr (HTTP ${GH_REST_STATUS:-000}). The verdict is $res; the body is $OUT/comment.md on the hub. It is not posted again." \
               alert --severity warn --id console-postmerge-qa-post
           fi
         fi ;;
      44) log "GitHub knows no PR for $C7 — comment NOT posted" ;;
      *) log "PR lookup for $C7 failed (rc=$rc HTTP ${GH_REST_STATUS:-000}) — NOT posted (GitHub unreadable)" ;;
    esac
  fi
  rm -f "$OUT/pulls.json" "$OUT/thread.json"

  case "$res" in
    PASS)
      ALERT_MSG="console post-merge QA PASS at $C7" alert --resolve --id console-postmerge-qa
      ALERT_MSG="console post-merge QA PASS at $C7" alert --resolve --id console-postmerge-qa-notcovered ;;
    FAIL)
      local gfl="" gfrc=0 orc=0
      # shellcheck source=bin/lib/group-findings.sh
      if [ -n "$SLUG" ] && { . "$H/bin/lib/group-findings.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/group-findings.sh" 2>/dev/null; }; then
        gf_from_observed cromford "$OUT/observed.json" > "$OUT/qa-findings.jsonl" 2>/dev/null || orc=$?
        GF_RUN_ID="console-postmerge-qa-$C7" gf_run "$OUT/qa-findings.jsonl" "$OUT" "$SLUG" >/dev/null 2>&1 || gfrc=$?
        gfl=$(tail -n 1 "$OUT/group-findings.md" 2>/dev/null)
        [ "$orc" = 0 ] || gfl="observed.json unreadable (rc=$orc), nothing grouped; ${gfl:-group-findings: no summary written}"
        log "${gfl:-group-findings: no summary written} (rc=$gfrc)"
        case "$orc:$gfrc" in 0:0) gfl="" ;; esac
      fi
      first=$(grep -m1 '^FAIL: ' "$OUT/qa.md" 2>/dev/null | cut -c7-200)
      ALERT_MSG="[$(hostname)] console post-merge QA FAIL at $C7: ${first:-see the report} — state/console-postmerge-qa/$CSHA/qa.md${gfl:+ ${gfl}}" \
        alert --severity warn --id console-postmerge-qa
      ALERT_MSG="console post-merge QA observed $C7" alert --resolve --id console-postmerge-qa-notcovered ;;
    *)
      ALERT_MSG="[$(hostname)] console post-merge QA NOT COVERED at $C7: ${v#NOT_COVERED } — logs/console-postmerge-qa.log" \
        alert --severity warn --id console-postmerge-qa-notcovered ;;
  esac
  exit 0
}

# 1. The deploy tree: the commit's functions/ and src/, the kept dist/.
TREE=$(mktemp -d "$H/state/console-postmerge-snap.XXXXXX") || report "NOT_COVERED deploy tree failed (no snapshot dir)"
git -C "$CO" archive "$CSHA" console-ui/functions console-ui/src | tar -x -C "$TREE"
ps=("${PIPESTATUS[@]}")
[ "${ps[0]}" = 0 ] && [ "${ps[1]}" = 0 ] || report "NOT_COVERED deploy tree failed (git archive rc=${ps[0]}, tar rc=${ps[1]})"
# BH-6487: the proxy's #coord-writes import needs package.json and the rendered table.
CWHY=$(cpv_coord_writes "$CO" "$CSHA" "$TREE" 2>&1) || report "NOT_COVERED deploy tree failed (coord write table: ${CWHY:-no reason})"
mkdir -p "$TREE/worker/jobs"
git -C "$CO" show "$CSHA:worker/jobs/wrangler.jsonc" > "$TREE/worker/jobs/wrangler.jsonc" 2>/dev/null || rm -f "$TREE/worker/jobs/wrangler.jsonc"
cp -RP -- "$DIST" "$TREE/console-ui/dist" || report "NOT_COVERED deploy tree failed (dist copy)"
[ -n "$URL" ] || report "NOT_COVERED deploy tree failed (no console Pages host)"

# 2. The upload. The token only ever lives in this subshell's env.
( set -a; . "$CFENV"; set +a
  acct=$(console_pages_account_id "$TREE") && [ -n "$acct" ] && export CLOUDFLARE_ACCOUNT_ID="$acct"
  export npm_config_userconfig=/dev/null npm_config_globalconfig=/dev/null \
         npm_config_registry=https://registry.npmjs.org/ npm_config_cache="$TREE/.npm"
  cd "$TREE/console-ui" && timeout 600 npx --yes "wrangler@$WRANGLER" pages deploy dist --project-name "$(console_pages_project)" \
    --branch "$ALIAS" --commit-hash "$CSHA" --commit-message "post-merge QA $C7" </dev/null ) >"$TREE/deploy.log" 2>&1
DRC=$?
CFTOK=$( set -a; . "$CFENV" >/dev/null 2>&1; printf '%s' "${CLOUDFLARE_API_TOKEN:-}" )
scrub "$TREE/deploy.log" "$CFTOK" > "$TREE/deploy.clean"; unset CFTOK
tail -n 5 "$TREE/deploy.clean" | sed 's/^/  wrangler: /'
if [ "$DRC" != 0 ] || ! grep -q 'Deployment complete' "$TREE/deploy.clean"; then
  report "NOT_COVERED alias deploy failed (rc=$DRC)"
fi
log "$C7 deployed to $URL"

# 3. The QA session, minted from the console worker. HARNESS_SECRET stays in a subshell.
TOKEN=$( hs=$( set -a; . "$HENV/global.env" >/dev/null 2>&1; set +a; printf '%s' "${HARNESS_SECRET:-}" )
  [ -n "$hs" ] || exit 0
  curl -sS --max-time 30 -X POST -H "Authorization: Bearer $hs" -H 'content-type: application/json' \
    -d '{"ttl_s":1800}' "${CONSOLE_WORKER_URL:-https://harness-console.${HARNESS_WORKERS_SUBDOMAIN:-}.workers.dev}/api/qa/session" 2>/dev/null \
    | jq -r '.token // empty' 2>/dev/null )
[[ "$TOKEN" =~ ^[0-9]+\.[0-9a-f]{64}$ ]] || report "NOT_COVERED no QA session minted (POST /api/qa/session; cromford-console #46 must be deployed)"

# 4. The drive. The screens split on spaces and never glob.
QRC=0
set -f
# shellcheck disable=SC2086
CONSOLE_QA_TOKEN="$TOKEN" CONSOLE_QA_WIDTHS=1280,375 timeout 600 node "$H/bin/console-qa-run.mjs" "$URL" "$H" "$OUT" $SCREENS \
  > "$TREE/drive.log" 2>&1 || QRC=$?
set +f
scrub "$TREE/drive.log" "$TOKEN" > "$OUT/qa.md"
unset TOKEN
cov=$(grep '^QA COVERAGE: ' "$OUT/qa.md" | tail -n 1)
[ -n "$cov" ] || report "NOT_COVERED drive printed no QA COVERAGE line (rc=$QRC)"
scr=$(sed -n 's/.* screens=\([0-9]*\).*/\1/p' <<<"$cov"); sht=$(sed -n 's/.* shots=\([0-9]*\).*/\1/p' <<<"$cov")
[ "${scr:-0}" -ge 1 ] || report "NOT_COVERED drive observed no screen"
if [ "$QRC" = 0 ] && grep -qx 'QA: PASS' "$OUT/qa.md" && ! grep -qx 'QA: FAIL' "$OUT/qa.md" && [ "${sht:-0}" -ge 1 ]; then
  report PASS
fi
report FAIL
