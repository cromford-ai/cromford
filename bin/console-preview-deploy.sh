#!/bin/bash
# bin/console-preview-deploy.sh — hub lane (cron/lanes/727-console-preview-deploy.cron,
# every 5 minutes): one Cloudflare Pages PREVIEW deploy of each open PR head
# that changes console-ui/, under the PR's branch alias, then a browser QA run
# of the preview signed in as a READ-ONLY QA session, then ONE PR comment with
# the preview URL, `QA COVERAGE`, `QA: PASS|FAIL` and the head sha (BH-5909
# slice 1).
#
# WHY. Pages got console-ui only after merge, so console PRs merged with no
# browser QA (the Mission Control redesign, #4990..#4993). The lane reads open
# PRs, not build directories, so a PR built on a Mac or by hand gets QA too.
#
# OFF BY DEFAULT (CONSOLE_PREVIEW_DEPLOY, a settings row, default 0). It is
# turned on after the first green proof on a real console PR.
#
# PER PR, cheapest check first:
#   1. a same-repo head only. A fork's package.json would run on the hub.
#   2. state/console-preview-deploy/<sha> already says done or no-console: skip.
#   3. fetch refs/pull/<n>/head into the checkout's object store (no ref, no
#      worktree change); a diff with no console-ui/ path is recorded no-console.
#   4. the PR comments (bin/lib/console-preview.sh cpv_comments). A marker for
#      this head and URL: recorded done. An unreadable thread: skipped.
#   5. over CONSOLE_PREVIEW_MAX_PER_RUN deploys, or 2 x that many build
#      attempts, this run: deferred to the next tick.
#   6. the build (`npm ci --ignore-scripts`, vite build) runs in its own copy of
#      the head under $CONSOLE_PREVIEW_BUILD_TMP, as an unprivileged user with a
#      clean env (cpv_run_unpriv). Only the plain files of dist come back.
#      Each build command runs in its own PID namespace, so nothing it starts
#      outlives it, and no build starts while a process of the build user is
#      alive (BH-6073).
#   7. THE DEPLOY TREE HOLDS NO FILE FROM THE PR BUT ITS BUILT dist/. Its
#      functions/ and the src/ they import are origin/main's (reviewed), so a
#      PR's Functions code never runs on Pages before review. There is no
#      package.json, .npmrc or wrangler.toml in it. npx runs a pinned wrangler
#      (CONSOLE_PREVIEW_WRANGLER, 3.114.17) with npm's user and global config
#      off and the registry pinned, and the account id comes from the hub's
#      cloudflare.env, else from origin/main's worker/jobs/wrangler.jsonc.
#      Before the first deploy of a run, the lane checks that the Pages
#      project's PREVIEW environment has no production write binding (no D1,
#      KV or R2, no secret-named env var). A binding found is removed with ONE
#      PATCH that touches only deployment_configs.preview
#      (CONSOLE_PREVIEW_STRIP_BINDINGS, default 1), then the config is read
#      again. A re-read that still binds something, a PATCH that fails, or a
#      config that does not read stops every deploy this run with one alert.
#   8. QA: the hub mints a read-only QA session from the console worker
#      (POST /api/qa/session, Bearer HARNESS_SECRET; cromford-console #46)
#      and bin/console-qa-run.mjs signs in on the PREVIEW origin
#      (/qa-login/<token>), then loads CONSOLE_PREVIEW_QA_SCREENS (default "/")
#      at 1440px and 390px with headless chromium. It only loads pages; it
#      never clicks. Screenshots stay on the hub under
#      state/console-preview-qa/<pr>-<sha12>/.
# Deploy first, QA second, comment last: a failed deploy posts nothing. The
# comment body is kept under state/console-preview-qa/<pr>-<sha12>/comment.md,
# and a rejected POST records `posting <n>`, so later ticks post that body again
# with no rebuild, up to CONSOLE_PREVIEW_MAX_ATTEMPTS, then one alert.
# WHO PAYS FOR A FAILURE. Only the head's own fault (its npm ci or vite build
# failed, or its dist/ was refused) records `failed <n>` and counts toward
# CONSOLE_PREVIEW_MAX_ATTEMPTS. A fault of the box (no build dir, no isolation,
# a copy that failed, a wrangler auth, network, rate or 5xx error) charges no
# head: the run stops at once and raises one console-preview-box alert, so a
# broken hub never makes every open console PR terminal. Only an upload Pages
# refuses for the head's own dist/ is the head's; any other upload error,
# unknown ones included, is the box's. A 401, 403 or 429 is the box's only
# after an error word, never inside a file name (dist/403.html). And one head
# never stalls the lane: the same head as the run's upload box fault more than
# MAX_ATTEMPTS runs in a row is skipped so the next head is tried, and is
# charged only if a later head uploads in that run, the run did not stop on a
# box fault, and it then fails again (state/console-preview-deploy/.box-streak).
# The streak survives a charge, so the next run skips that head with no alert.
# A retry that uploads runs QA and posts the comment like any other deploy.
#
# Knobs (catalog/lanes.d/console-preview-deploy.json, lane_env_apply):
# CONSOLE_PREVIEW_DEPLOY (0), CONSOLE_PREVIEW_MAX_PER_RUN (3),
# CONSOLE_PREVIEW_QA_SCREENS ("/"), CONSOLE_PREVIEW_BUILD_USER (nobody),
# CONSOLE_PREVIEW_BUILD_TMP (/tmp), CONSOLE_PREVIEW_WRANGLER (3.114.17),
# CONSOLE_PREVIEW_STRIP_BINDINGS (1).
# Off switch: bin/harness-ctl.sh off console-preview-deploy.
# Secrets: the API token lives only in the deploy subshell's env and is scrubbed
# from the deploy log; HARNESS_SECRET and the QA token never reach a log line or
# the comment. Never deploys --branch main (cpv_alias refuses it).
#
# Built from the pool's BH-5909 build (#5951), with its review's six findings
# answered; that PR is closed as superseded.
set -uo pipefail
H="${HARNESS:-/root/harness}"
CO="${HARNESS_CHECKOUT:-/root/harness-checkout}"
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit console-preview-deploy
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    console-preview-deploy
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }; HENV=$(harness_env_dir "$H")
CFENV="$HENV/cloudflare.env"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(STAMP) console-preview: $*"; }

# Not the hub: silent, before any network call.
[ -f "$CFENV" ] && [ -d "$CO/console-ui" ] && [ -e "$CO/.git" ] || exit 0

ON="${CONSOLE_PREVIEW_DEPLOY:-0}"
[ "$ON" = 1 ] || { log "CONSOLE_PREVIEW_DEPLOY=${ON} — off (default 0 until the first green proof)"; exit 0; }

. "$H/bin/lib/console-preview.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/console-preview.sh" 2>/dev/null \
  || { log "bin/lib/console-preview.sh missing — not deploying"; exit 0; }
. "${HARNESS_DEPLOYMENT_FILE-$H/bin/lib/deployment.sh}" 2>/dev/null || true
SLUG="${HARNESS_REPO:-}"
[ -n "$SLUG" ] || { log "HARNESS_REPO unset — not deploying"; exit 0; }

MAX="${CONSOLE_PREVIEW_MAX_PER_RUN:-3}"
case "$MAX" in ''|*[!0-9]*) log "CONSOLE_PREVIEW_MAX_PER_RUN='$MAX' is not a number — using 3"; MAX=3 ;; esac
# A head whose build or deploy failed this many times is terminal: one comment
# says so, and no later run builds it again (a new push is a new head).
MAXATT="${CONSOLE_PREVIEW_MAX_ATTEMPTS:-2}"
case "$MAXATT" in ''|*[!0-9]*|0) log "CONSOLE_PREVIEW_MAX_ATTEMPTS='$MAXATT' is not a positive number — using 2"; MAXATT=2 ;; esac
WRANGLER="${CONSOLE_PREVIEW_WRANGLER:-3.114.17}"
[[ "$WRANGLER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { log "CONSOLE_PREVIEW_WRANGLER='$WRANGLER' is not an exact version — using 3.114.17"; WRANGLER=3.114.17; }
SCREENS="${CONSOLE_PREVIEW_QA_SCREENS:-/}"

SD="$H/state/console-preview-deploy"
QD="$H/state/console-preview-qa"
mkdir -p "$SD" "$QD" "$H/locks" "$H/logs"
# Dedupe, never a queue.
exec 5>"$H/locks/console-preview-deploy.lock"
flock -n 5 || exit 0
for old in "$H"/state/console-preview-snap.*; do
  case "$old" in "$H/state/console-preview-snap."?*) [ -d "$old" ] && rm -rf -- "$old" ;; esac
done
# The local record is a cost cache, never the truth (the marker is): 14 days.
find "$SD" -maxdepth 1 -type f -mtime +14 -delete 2>/dev/null
find "$QD" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf -- {} + 2>/dev/null

TMP=$(mktemp -d "${TMPDIR:-/tmp}/console-preview.XXXXXX") || exit 0
D=""; B=""
BT="${CONSOLE_PREVIEW_BUILD_TMP:-/tmp}"
find "$BT" -maxdepth 1 -type d -name 'console-preview-build.?*' -mmin +60 -exec rm -rf -- {} + 2>/dev/null
cleanup_build() { case "$B" in "$BT/console-preview-build."?*) rm -rf -- "$B" ;; esac; B=""; }
trap 'rm -rf -- "$TMP"; case "$D" in "$H/state/console-preview-snap."?*) rm -rf -- "$D" ;; esac; cleanup_build' EXIT
trap 'exit 143' TERM INT

git -C "$CO" fetch -q origin main >/dev/null 2>&1 || { log "git fetch origin main failed — not deploying"; exit 0; }

# The account id: the hub's cloudflare.env, else origin/main's (never the PR's).
ACCT=$( set -a; . "$CFENV" >/dev/null 2>&1; set +a; printf '%s' "${CLOUDFLARE_ACCOUNT_ID:-}" )
if [ -z "$ACCT" ]; then
  mkdir -p "$TMP/main/worker/jobs"
  git -C "$CO" show origin/main:worker/jobs/wrangler.jsonc > "$TMP/main/worker/jobs/wrangler.jsonc" 2>/dev/null
  ACCT=$(CLOUDFLARE_ACCOUNT_ID="" console_pages_account_id "$TMP/main" 2>/dev/null) || ACCT=""
fi
[[ "$ACCT" =~ ^[0-9a-zA-Z-]{6,64}$ ]] || { log "no Cloudflare account id (cloudflare.env or origin/main's worker/jobs/wrangler.jsonc) — not deploying"; exit 0; }

# cpv_scrub <file> — the file with the API token and any Bearer value replaced.
TOKV=$( set -a; . "$CFENV" >/dev/null 2>&1; set +a; printf '%s' "${CLOUDFLARE_API_TOKEN:-}" )
cpv_scrub() { CP_TOK="$TOKV" awk '{t=ENVIRON["CP_TOK"]; if (t!="") while ((i=index($0,t))>0) $0=substr($0,1,i-1) "***" substr($0,i+length(t)); gsub(/Bearer[ \t]+[^ \t]+/,"Bearer ***"); print}' "$1"; }

# THE PREVIEW ENVIRONMENT HAS NO PRODUCTION WRITE BINDING, or nothing deploys.
# Fail closed: every non-empty key of the preview config that is not a plain
# setting is a binding (D1, KV, R2, services, Durable Objects, queues, AI,
# Hyperdrive, Analytics Engine, and whatever Cloudflare adds next), and an env
# var is a secret when its type is secret_text or its name says so.
PREVIEW_JQ='.result.deployment_configs.preview as $p
  | def plain: IN("env_vars","compatibility_date","compatibility_flags","usage_model","fail_open",
                  "always_use_latest_compatibility_date","build_image_major_version","placement",
                  "limits","wrangler_config_hash");
    def secret: ((.value.type // "") == "secret_text") or (.key | test("SECRET|TOKEN|KEY|PASSWORD"; "i"));
    def bindings: $p | to_entries[] | select(.key | plain | not)
      | select((.value | type) as $t | ($t == "object" or $t == "array") and (.value | length) > 0);
    def secrets: ($p.env_vars // {}) | to_entries[] | select(secret);'
# preview_findings <project.json> — the findings as one comma list; empty = clean.
preview_findings() {
  jq -r "$PREVIEW_JQ"' [ (bindings | "\(.key) \(.value | if type == "object" then keys | join("/") else length | tostring end)"),
                          (secrets | "env var \(.key)") ] | join(", ")' "$1"
}
# preview_strip_body <project.json> — {deployment_configs:{preview:{…nulls}}}:
#   each object-typed binding's names and each secret env var set to null. An
#   array-typed binding cannot be nulled by name, so it is listed in .cannot.
#   The body never holds a production key or a plain env var.
preview_strip_body() {
  jq -c "$PREVIEW_JQ"' ([bindings | select(.value | type == "object") | {key, value: (.value | map_values(null))}] | from_entries)
      + ([secrets | {key, value: null}] | if length > 0 then {env_vars: from_entries} else {} end)
    | {body: {deployment_configs: {preview: .}}, cannot: [bindings | select(.value | type == "array") | .key]}' "$1"
}
STRIP="${CONSOLE_PREVIEW_STRIP_BINDINGS:-1}"
case "$STRIP" in 0|1) ;; *) log "CONSOLE_PREVIEW_STRIP_BINDINGS='$STRIP' is not 0 or 1 — using 1"; STRIP=1 ;; esac
# get_project — the Pages project config into $TMP/project.json; rc 0 = read.
get_project() {
  ( set -a; . "$CFENV"; set +a
    curl -sS --max-time 30 -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN:-}" \
      "${CONSOLE_PREVIEW_CF_API:-https://api.cloudflare.com/client/v4}/accounts/$ACCT/pages/projects/$(console_pages_project)" ) \
    > "$TMP/project.json" 2>"$TMP/project.err"
}
# strip_preview_bindings — ONE PATCH that nulls the preview findings of
#   $TMP/project.json. rc 0 when Cloudflare answers success; rc 1 with
#   STRIP_WHY set. The token stays in the subshell; the response is never logged.
STRIP_WHY=""
strip_preview_bindings() {
  local plan cannot
  plan=$(preview_strip_body "$TMP/project.json" 2>/dev/null) || { STRIP_WHY="the strip body did not build"; return 1; }
  cannot=$(jq -r '.cannot | join(", ")' <<<"$plan")
  [ -n "$cannot" ] && { STRIP_WHY="array-typed bindings cannot be removed by name: $cannot"; return 1; }
  jq -c '.body' <<<"$plan" > "$TMP/strip.json"
  jq -e '.deployment_configs.preview | length > 0' "$TMP/strip.json" >/dev/null 2>&1 || { STRIP_WHY="nothing to remove by name"; return 1; }
  if ! ( set -a; . "$CFENV"; set +a
         curl -sS --max-time 30 -X PATCH -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN:-}" -H 'content-type: application/json' \
           --data-binary @"$TMP/strip.json" \
           "${CONSOLE_PREVIEW_CF_API:-https://api.cloudflare.com/client/v4}/accounts/$ACCT/pages/projects/$(console_pages_project)" ) \
         > "$TMP/strip.out" 2>"$TMP/strip.err"; then
    STRIP_WHY="the PATCH did not complete ($(cpv_scrub "$TMP/strip.err" | tail -n 1 | cut -c1-160))"; return 1
  fi
  jq -e '.success == true' "$TMP/strip.out" >/dev/null 2>&1 \
    || { STRIP_WHY="Cloudflare did not answer success to the PATCH ($(jq -r '[.errors[]?.code // empty] | map(tostring) | join(",")' "$TMP/strip.out" 2>/dev/null | cut -c1-80))"; return 1; }
  return 0
}
BINDINGS_OK=""
preview_bindings_clean() {
  [ -n "$BINDINGS_OK" ] && { [ "$BINDINGS_OK" = yes ]; return; }
  local why="" found why2
  if ! get_project; then
    why="the Pages project config did not read"
  elif ! jq -e '.success == true and (.result.deployment_configs.preview | type == "object")' "$TMP/project.json" >/dev/null 2>&1; then
    why="the Pages project config did not answer success with a preview config"
  else
    found=$(preview_findings "$TMP/project.json" 2>/dev/null) || found="(the config did not parse)"
    if [ -n "$found" ]; then
      why="the preview environment has production bindings: $found"
      # At most one strip per run; the re-read decides, never the PATCH answer.
      if [ "$STRIP" = 1 ]; then
        if strip_preview_bindings; then
          if ! get_project; then
            why="$why; the lane removed them, but the re-read of the config failed"
          else
            why2=$(preview_findings "$TMP/project.json" 2>/dev/null) || why2="(the config did not parse)"
            if [ -z "$why2" ] && jq -e '.success == true and (.result.deployment_configs.preview | type == "object")' "$TMP/project.json" >/dev/null 2>&1; then
              why=""
              log "removed from the preview environment: $found (Pages project $(console_pages_project)); the re-read is clean"
              [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --log-only console-preview-deploy \
                "[console-preview] The lane removed $found from the preview environment of Pages project $(console_pages_project). The production environment is not changed. The re-read shows no binding and no secret, so previews deploy again." >/dev/null 2>&1 || true
              [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --resolve --id console-preview-bindings console-preview-deploy \
                "[console-preview] The preview environment binds nothing now; previews deploy again." >/dev/null 2>&1 || true
            else
              why="the preview environment still has production bindings after the lane removed them: ${why2:-the re-read did not answer success}"
            fi
          fi
        else
          why="$why; the lane could not remove them: $STRIP_WHY"
        fi
      fi
    fi
  fi
  if [ -n "$why" ]; then
    BINDINGS_OK=no
    log "$why — no preview is deployed this run"
    [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --id console-preview-bindings console-preview-deploy \
      "[console-preview] $why. A preview runs unreviewed code against whatever Pages binds to its preview environment, so no preview deploys until it binds nothing (no D1, KV, R2, service, Durable Object or other binding) and no secret (Pages project $(console_pages_project), Settings -> Preview). CONSOLE_PREVIEW_STRIP_BINDINGS=$STRIP." >/dev/null 2>&1 || true
    return 1
  fi
  BINDINGS_OK=yes
  return 0
}

rc=0; gh_rest_pr_list "$SLUG" open > "$TMP/prs.json" || rc=$?
[ "$rc" = 0 ] || { log "open PR list unreadable (rc=$rc HTTP ${GH_REST_STATUS:-000}) — not deploying"; exit 0; }
jq -r --arg s "$SLUG" '.[]? | [(.number|tostring), (.head.ref // ""), (.head.sha // ""),
  (if (.head.repo.full_name // "" | ascii_downcase) == ($s | ascii_downcase) then "same" else "fork" end)] | @tsv' \
  "$TMP/prs.json" > "$TMP/prs.tsv" 2>/dev/null || { log "open PR list did not parse — not deploying"; exit 0; }

# deploy_one <n> <alias> <sha> <url> — rc 0 only on a complete deploy.
#   rc 1  the HEAD's own fault: its npm ci or vite build failed, or its dist was
#         refused. Only this counts toward CONSOLE_PREVIEW_MAX_ATTEMPTS.
#   rc 3  the BOX's fault, not the head's (lead BLOCK at 54f3dfea9): no build
#         dir, a copy that failed, a build that cannot be isolated (rc 125: no
#         setpriv, no build user, a dir it cannot write), main's Functions not
#         copied, a wrangler or Cloudflare error. BOX_WHY says which. It is never
#         charged to a head: the run stops and raises one alert.
#   An UPLOAD failure is classified from wrangler's own words: only a dist
#   Pages refuses (a file too large, too many files, a bad _headers or
#   _redirects) is the head's (rc 1). Everything else is the box's (rc 3,
#   BOX_STAGE=upload): auth, network, rate, a 5xx, npm's own errors (npm 10
#   prints `npm error code ENOSPC`), a timeout (rc 124), a kill (rc 137) and any
#   error nobody classified (lead BLOCK at 1f9246916). A head that keeps being
#   the upload box fault is freed by the streak guard in the main loop.
BOX_WHY=""; BOX_STAGE=""
# upload_fault <clean log> <wrangler rc> — box | head
# A 401, 403 or 429 is the box's only after an error word (`HTTP 403`,
# `status: 429`, `Error 401.`), never inside a file name (`dist/403.html`).
# The head patterns read wrangler's error block only (from the first
# `[ERROR]` line on). Wrangler logs `Uploading _headers` and `Uploading
# _redirects` on every deploy before its /deployments POST, so a head pattern
# run over the whole log would charge any unknown later failure to the head
# (lead review lr-6056-72e007976067). No error block = an unknown fault = box.
upload_fault() {
  local err
  case "$2" in 124|137) echo box; return ;; esac
  err=$(sed -n '/\[ERROR\]/,$p' "$1")
  if grep -qiE 'authentication error|code: 10000|unauthori[sz]ed|forbidden|invalid api token|(status|http|code|error|received|returned|response)[^0-9a-z/]{0,12}(401|403|429)([^0-9a-z./_-]|\.([^a-z0-9]|$)|$)|enotfound|econnreset|econnrefused|etimedout|eai_again|fetch failed|getaddrinfo|socket hang up|rate limit|too many requests|internal server error|service unavailable|bad gateway|gateway time-?out|npm (err!|error)|enospc|enomem|eacces|etarget' "$1"; then
    echo box
  elif [ -n "$err" ] && grep -qiE 'mib in size|too large|exceeds|too many files|maximum number of files|_redirects|_headers|invalid (asset|file|path)' <<<"$err"; then
    echo head
  else
    echo box
  fi
}
deploy_one() {
  local n="$1" alias="$2" sha="$3" url="$4" s7=${3:0:7} drc ps urc=0 brc=0 why
  BOX_STAGE=build
  box() { BOX_WHY="$1"; log "#$n $1 at $s7 — not charged to the head; this run stops"; return 3; }
  # 1. The build: the PR head in its own tree, unprivileged, clean env, no
  #    install scripts. Only its dist's plain files come back.
  B=$(mktemp -d "$BT/console-preview-build.XXXXXX") || { box "no build dir under $BT"; return; }
  git -C "$CO" archive "$sha" console-ui worker catalog | tar -x -C "$B"
  ps=("${PIPESTATUS[@]}")
  [ "${ps[0]}" = 0 ] && [ "${ps[1]}" = 0 ] || { box "build copy failed (git archive rc=${ps[0]}, tar rc=${ps[1]})"; return; }
  D=$(mktemp -d "$H/state/console-preview-snap.XXXXXX") || { box "no snapshot dir under $H/state"; return; }
  cpv_run_unpriv "$B" "$B/console-ui" 600 npm ci --ignore-scripts --no-audit --no-fund >"$D/ci.log" 2>&1 || urc=$?
  [ "$urc" = 125 ] && { box "build not isolated: $(tail -n 1 "$D/ci.log")"; return; }
  [ "$urc" = 0 ] || { log "#$n npm ci failed at $s7 — preview not deployed"; return 1; }
  cpv_run_unpriv "$B" "$B/console-ui" 300 npm run build >"$D/build.log" 2>&1 || brc=$?
  [ "$brc" = 125 ] && { box "build not isolated: $(tail -n 1 "$D/build.log")"; return; }
  [ "$brc" = 0 ] || { log "#$n vite build failed at $s7 — preview not deployed"; return 1; }
  # 2. The deploy tree: origin/main's functions/ and src/, the PR's dist/ only.
  git -C "$CO" archive origin/main console-ui/functions console-ui/src | tar -x -C "$D"
  ps=("${PIPESTATUS[@]}")
  [ "${ps[0]}" = 0 ] && [ "${ps[1]}" = 0 ] || { box "main's functions could not be copied (git archive rc=${ps[0]}, tar rc=${ps[1]})"; return; }
  # BH-6487: the proxy's #coord-writes import needs package.json and the rendered table.
  why=$(cpv_coord_writes "$CO" origin/main "$D" 2>&1) || { box "main's coord write table did not render (${why:-no reason})"; return; }
  cpv_copy_dist "$B/console-ui/dist" "$D/console-ui/dist" 2>>"$D/build.log" \
    || { log "#$n build output of $s7 refused: $(tail -n 1 "$D/build.log") — preview not deployed"; return 1; }
  grep -q '^cpv_copy_dist: stripped' "$D/build.log" && log "#$n $(grep '^cpv_copy_dist: stripped' "$D/build.log" | tail -n 1 | sed 's/^cpv_copy_dist: //') (Pages would run them as server code; main's Functions deploy instead)"
  # 3. The upload: pinned wrangler, no npm config from anywhere, pinned registry.
  ( set -a; . "$CFENV"; set +a
    export CLOUDFLARE_ACCOUNT_ID="$ACCT" npm_config_userconfig=/dev/null npm_config_globalconfig=/dev/null \
           npm_config_registry=https://registry.npmjs.org/ npm_config_cache="$D/.npm"
    cd "$D/console-ui" && timeout 600 npx --yes "wrangler@$WRANGLER" pages deploy dist --project-name "$(console_pages_project)" \
      --branch "$alias" --commit-hash "$sha" --commit-message "preview PR #$n $s7" </dev/null ) >"$D/deploy.log" 2>&1
  drc=$?
  cpv_scrub "$D/deploy.log" > "$D/deploy.clean"
  tail -n 5 "$D/deploy.clean" | sed "s/^/  #$n wrangler: /"
  if [ "$drc" != 0 ] || ! grep -q 'Deployment complete' "$D/deploy.clean"; then
    BOX_STAGE=upload
    why="wrangler rc=$drc: $(grep -iE 'error|✘' "$D/deploy.clean" | tail -n 1 | cut -c1-200)"
    if [ "$(upload_fault "$D/deploy.clean" "$drc")" = head ]; then
      log "#$n preview deploy failed at $s7: Pages refused the head's own dist/ ($why) — charged to the head"; return 1
    fi
    box "preview deploy failed on the box side ($why) — no comment, the next tick retries"; return
  fi
  log "#$n preview deployed at $s7: $url"
  return 0
}

# qa_one <n> <sha> <url> <outdir> — writes <outdir>/qa.md; rc 0 PASS, 1 FAIL.
# The session is minted here and handed to the driver in its env only.
qa_one() {
  local n="$1" sha="$2" url="$3" out="$4" tok resp qrc=0 hs
  mkdir -p "$out"
  hs=$( set -a; . "$HENV/global.env" >/dev/null 2>&1; set +a; printf '%s' "${HARNESS_SECRET:-}" )
  if [ -z "$hs" ]; then
    printf 'FAIL: HARNESS_SECRET is not set on this box — no QA session was minted\nQA COVERAGE: screens=0 flows=0 shots=0\nQA: FAIL\n' > "$out/qa.md"
    return 1
  fi
  resp=$(curl -sS --max-time 30 -X POST -H "Authorization: Bearer $hs" -H 'content-type: application/json' \
           -d '{"ttl_s":1800}' "${CONSOLE_WORKER_URL:-https://harness-console.$HARNESS_WORKERS_SUBDOMAIN.workers.dev}/api/qa/session" 2>/dev/null) || resp=""
  tok=$(jq -r '.token // empty' <<<"$resp" 2>/dev/null)
  if ! [[ "$tok" =~ ^[0-9]+\.[0-9a-f]{64}$ ]]; then
    printf 'FAIL: the console worker minted no QA session (POST /api/qa/session; cromford-console #46 must be deployed)\nQA COVERAGE: screens=0 flows=0 shots=0\nQA: FAIL\n' > "$out/qa.md"
    return 1
  fi
  # The screens split on spaces and never glob (a `*` in the knob is a path, not a file list).
  set -f
  # shellcheck disable=SC2086
  CONSOLE_QA_TOKEN="$tok" timeout 600 node "$H/bin/console-qa-run.mjs" "$url" "$H" "$out" $SCREENS > "$out/drive.log" 2>&1 || qrc=$?
  set +f
  CP_T="$tok" awk '{t=ENVIRON["CP_T"]; if (t!="") while ((i=index($0,t))>0) $0=substr($0,1,i-1) "***" substr($0,i+length(t)); print}' "$out/drive.log" > "$out/qa.md"
  rm -f "$out/drive.log"
  grep -q '^QA COVERAGE: ' "$out/qa.md" || printf 'QA COVERAGE: screens=0 flows=0 shots=0\n' >> "$out/qa.md"
  grep -qx 'QA: PASS\|QA: FAIL' "$out/qa.md" || printf 'QA: FAIL\n' >> "$out/qa.md"
  [ "$qrc" = 0 ] && grep -qx 'QA: PASS' "$out/qa.md"
}

# post_one <n> <sha> <body> <failed posts so far> — the comment from the kept
#   body. A rejected POST is retried from the same body on later ticks, never by
#   a rebuild, and stops with one alert at CONSOLE_PREVIEW_MAX_ATTEMPTS.
post_one() {
  local n="$1" sha="$2" body="$3" k="$4"
  if gh_rest_comment "$SLUG" "$n" "$body"; then
    echo done > "$SD/$sha"; log "#$n preview comment posted at ${sha:0:7}"
    return 0
  fi
  k=$((k + 1)); echo "posting $k" > "$SD/$sha"
  if [ "$k" -ge "$MAXATT" ]; then
    log "#$n preview comment for ${sha:0:7} rejected $k times (HTTP ${GH_REST_STATUS:-000}) — not posted again; the body is $body"
    [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --id console-preview-post console-preview-deploy \
      "[console-preview] GitHub rejected the preview comment for PR #$n head ${sha:0:12} $k times (HTTP ${GH_REST_STATUS:-000}). The preview is deployed and QA ran; the comment is $body on the hub. The lane does not post it again." >/dev/null 2>&1 || true
  else
    log "#$n preview comment failed (HTTP ${GH_REST_STATUS:-000}) — the next tick posts the kept body again, with no rebuild"
  fi
  return 1
}

# charge_fail <n> <sha> <attempts so far> — the head's own failure: record it,
#   and at CONSOLE_PREVIEW_MAX_ATTEMPTS post the one terminal comment.
charge_fail() {
  local n="$1" sha="$2" k=$(( $3 + 1 ))
  failed=$((failed + 1)); echo "failed $k" > "$SD/$sha"
  [ "$k" -ge "$MAXATT" ] || return 0
  {
    printf 'Console preview: not deployed for head %s.\n\n' "$sha"
    printf 'The build or the upload of this head failed %s times for a reason of its own (its npm ci or vite build, a dist/ the lane or Pages refused, or an upload that kept failing while other heads uploaded), so the console-preview-deploy lane stops trying it. No browser QA ran for this head. The reasons are in logs/console-preview-deploy.log on the hub. A new push is a new head, and it is tried again.\n' "$k"
    printf '<!-- console-preview-failed sha=%s -->\n' "$sha"
  } > "$TMP/fail-$n.md"
  gh_rest_comment "$SLUG" "$n" "$TMP/fail-$n.md" || log "#$n failure comment for ${sha:0:7} not posted (HTTP ${GH_REST_STATUS:-000})"
  log "#$n head ${sha:0:7} failed $k times — terminal, not built again"
}

# box_alert <n> <sha> — the one console-preview-box alert, from the loop or the retry.
box_alert() {
  [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --id console-preview-box console-preview-deploy \
    "[console-preview] The hub could not build or deploy a preview: $BOX_WHY (PR #$1 head ${2:0:12}). This is the box, not the PR: no head is charged, and this run stopped. Fix it on the hub; the next tick tries again. logs/console-preview-deploy.log has the lines." >/dev/null 2>&1 || true
}

# qa_and_post <n> <sha> <url> <outdir> — after a deploy: QA, the kept comment
#   body, then the comment (post_one records done or `posting <k>`).
qa_and_post() {
  local n="$1" sha="$2" url="$3" out="$4" res
  if qa_one "$n" "$sha" "$url" "$out"; then res=PASS; passed=$((passed + 1)); else res=FAIL; qfailed=$((qfailed + 1)); fi
  {
    printf 'Console preview: %s\n\n' "$url"
    printf 'Head %s, deployed to Cloudflare Pages by the console-preview-deploy lane. Its Functions are origin/main'"'"'s; only the built dist/ is this head'"'"'s.\n\n' "$sha"
    printf 'Browser QA of the preview, signed in as a read-only QA session (loads only, no clicks), at 1440px and 390px:\n\n```\n'
    grep -E '^(FAIL: |SCREEN |PREVIEW GAP: |QA COVERAGE: |QA: )' "$out/qa.md" | head -40
    printf '```\n\nQA: %s for head %s. Screenshots: %s on the hub.\n' "$res" "$sha" "$out"
    printf '<!-- console-preview sha=%s url=%s -->\n<!-- console-qa sha=%s result=%s -->\n' "$sha" "$url" "$sha" "$res"
  } > "$out/comment.md"
  log "#$n QA $res at ${sha:0:7}"
  post_one "$n" "$sha" "$out/comment.md" 0 || true
}

# THE STREAK HEAD (lead BLOCK at 1f9246916). A head that was the run's upload
# box fault more than MAX_ATTEMPTS runs in a row is skipped (PEND) so the run can
# try the next head. Only if a later head uploads in this run (PROVEN: the box
# can upload, set only by an upload after PEND) and the loop did not stop on a
# box fault (BOXSTOP) is the skipped head tried once more, and an upload box
# fault then is its own. The streak survives a charge that is not terminal, and
# another head's upload: only the head's own upload or its terminal charge ends
# it. A build-stage box fault on the retry raises the console-preview-box alert
# and charges nothing. An account-wide fault (a token that can read but not
# upload) never uploads anything, so it charges no head however long it lasts.
PEND=""; PEND_N=""; PEND_ALIAS=""; PEND_URL=""; PEND_NATT=0; PROVEN=0; BOXSTOP=0
seen=0; console=0; deployed=0; deferred=0; failed=0; passed=0; qfailed=0; terminal=0; attempts=0
# A per-run ceiling on build attempts, so failing heads cannot hold the lane for hours.
ACAP=$((MAX * 2))
while IFS=$'\t' read -r n br sha kind; do
  [[ "$n" =~ ^[0-9]+$ && "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
  seen=$((seen + 1)); s7=${sha:0:7}
  [ "$kind" = same ] || continue
  rec=$(cat "$SD/$sha" 2>/dev/null)
  case "$rec" in done|no-console) continue ;; esac
  natt=0; pk=-1
  case "$rec" in
    "failed "*) natt=${rec#failed }; [[ "$natt" =~ ^[0-9]+$ ]] || natt=0 ;;
    "posting "*) pk=${rec#posting }; [[ "$pk" =~ ^[0-9]+$ ]] || pk=0 ;;
  esac
  { [ "$natt" -ge "$MAXATT" ] || [ "$pk" -ge "$MAXATT" ]; } && { terminal=$((terminal + 1)); continue; }
  if ! git -C "$CO" fetch -q --no-write-fetch-head origin "refs/pull/$n/head" >/dev/null 2>&1 \
     || ! git -C "$CO" cat-file -e "$sha^{commit}" 2>/dev/null; then
    log "#$n head $s7 could not be fetched — skipped this tick"; continue
  fi
  trc=0; cpv_touches_console "$CO" origin/main "$sha" || trc=$?
  case "$trc" in
    0) ;;
    1) echo no-console > "$SD/$sha"; continue ;;
    *) log "#$n diff of $s7 did not read — skipped this tick"; continue ;;
  esac
  console=$((console + 1))
  alias=$(cpv_alias "$br") || { log "#$n branch '$br' has no usable Pages alias — skipped"; continue; }
  url=$(cpv_url "$alias") || { log "#$n no console Pages host — skipped"; continue; }
  crc=0; cpv_comments "$SLUG" "$n" "$TMP/c-$n.json" || crc=$?
  [ "$crc" = 0 ] || { log "#$n comments unreadable (rc=$crc HTTP ${GH_REST_STATUS:-000}) — skipped this tick"; continue; }
  if cpv_marker_seen "$TMP/c-$n.json" "$sha" "$url"; then echo done > "$SD/$sha"; continue; fi
  QO="$QD/$n-${sha:0:12}"
  if [ "$pk" -ge 0 ] && [ -s "$QO/comment.md" ]; then post_one "$n" "$sha" "$QO/comment.md" "$pk"; continue; fi
  if [ "$deployed" -ge "$MAX" ] || [ "$attempts" -ge "$ACAP" ]; then deferred=$((deferred + 1)); continue; fi
  preview_bindings_clean || break
  attempts=$((attempts + 1))
  drc=0; deploy_one "$n" "$alias" "$sha" "$url" || drc=$?
  case "$D" in "$H/state/console-preview-snap."?*) rm -rf -- "$D" ;; esac; D=""; cleanup_build
  if [ "$drc" = 3 ] && [ "$BOX_STAGE" = upload ] && [ -z "$PEND" ]; then
    # ONE HEAD NEVER STALLS THE LANE (see THE STREAK HEAD above).
    ss=""; sk=0; read -r ss sk < "$SD/.box-streak" 2>/dev/null
    [ "$ss" = "$sha" ] && [[ "$sk" =~ ^[0-9]+$ ]] || sk=0
    sk=$((sk + 1)); echo "$sha $sk" > "$SD/.box-streak"
    if [ "$sk" -gt "$MAXATT" ]; then
      PEND="$sha"; PEND_N="$n"; PEND_ALIAS="$alias"; PEND_URL="$url"; PEND_NATT="$natt"
      log "#$n head $s7 was this run's upload box fault $sk runs in a row — skipped; it is tried again, and charged, only if a later head uploads this run"
      continue
    fi
  fi
  if [ "$drc" = 3 ]; then
    box_alert "$n" "$sha"
    BOXSTOP=1; break
  fi
  if [ "$drc" != 0 ]; then
    # A failure takes no MAX_PER_RUN slot (lead BLOCK at 9935bb529): only a
    # deploy that worked counts. Only the head's own failure is recorded, so a
    # broken head stops being rebuilt once it reaches
    # CONSOLE_PREVIEW_MAX_ATTEMPTS; a box fault (rc 3) is never charged.
    charge_fail "$n" "$sha" "$natt"
    continue
  fi
  deployed=$((deployed + 1))
  # Only an upload AFTER the streak head was skipped proves the box can upload.
  [ -n "$PEND" ] && PROVEN=1
  # Only the streak head's own upload ends its streak.
  ss=""; read -r ss _ 2>/dev/null < "$SD/.box-streak"
  [ "$ss" = "$sha" ] && rm -f "$SD/.box-streak"
  qa_and_post "$n" "$sha" "$url" "$QO"
done < "$TMP/prs.tsv"

# The streak head, once a later head proved the box can upload and the loop
# did not stop on a box fault: one more try.
if [ -n "$PEND" ] && [ "$PROVEN" = 1 ] && [ "$BOXSTOP" = 0 ]; then
  drc=0; deploy_one "$PEND_N" "$PEND_ALIAS" "$PEND" "$PEND_URL" || drc=$?
  case "$D" in "$H/state/console-preview-snap."?*) rm -rf -- "$D" ;; esac; D=""; cleanup_build
  if [ "$drc" = 0 ]; then
    rm -f "$SD/.box-streak"
    deployed=$((deployed + 1))
    qa_and_post "$PEND_N" "$PEND" "$PEND_URL" "$QD/$PEND_N-${PEND:0:12}"
  elif [ "$drc" = 1 ] || [ "$BOX_STAGE" = upload ]; then
    log "#$PEND_N head ${PEND:0:7} failed its upload again while another head uploaded this run — charged to the head"
    charge_fail "$PEND_N" "$PEND" "$PEND_NATT"
    # The streak survives a charge, so the next run skips the head at once,
    # with no alert; a terminal head is never tried again, so its streak ends.
    [ $((PEND_NATT + 1)) -ge "$MAXATT" ] && rm -f "$SD/.box-streak"
  else
    box_alert "$PEND_N" "$PEND"
  fi
fi
log "open PRs $seen, console heads $console, deploys $deployed (failed $failed), QA pass $passed fail $qfailed, deferred $deferred (max_per_run $MAX), terminal heads $terminal"
exit 0
