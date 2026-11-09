#!/bin/bash
# bin/console-pages-deploy.sh — deploy console-ui to Cloudflare Pages from the
# hub, once per console-ui commit on main (BH-3563, the BH-3554.2 slice). Run by
# bin/harness-sync.sh's "console pages deploy" block, DETACHED, only where
# cloudflare.env is; never run by cron. Output goes to stdout, which that block
# sends to logs/console-pages-deploy.log.
#
# WHY. Pages was deployed only by hand, and the live console sat 15 days on
# dee684a1 while about 230 console-ui commits merged, so SETTINGS (#1132) and
# PROJECT ACCOUNTS (#1657) were invisible.
#
# WHAT IT DOES. The key is main's last first-parent commit touching console-ui/
# (console_pages_want in bin/lib/console-pages.sh). The settings row
# deploy.console-ui.sha holds the last deployed one. A row equal to the key, or
# a descendant of it (a newer hand deploy), exits before any work, so a no-op
# run costs one `git rev-list` and one settings GET. Otherwise, in a snapshot of
# the checkout's HEAD under state/ (console-ui, worker, catalog, bin and tests,
# each one the commit has: the suites import ../worker and ../catalog, source
# ../bin/lib/*.sh and read ../tests/fixtures/, BH-9115; nothing is ever written
# under the checkout): npm ci, npm test, vite build, `wrangler@3 pages deploy`,
# then the stamp, then two anonymous probes that must answer 403.
# Force a redeploy: jobs-client.sh setting-set deploy.console-ui.sha none.
#
# FAILURE. Every stop is exit 0 plus a log line or a lane-alert under
# fleet-propagate; nothing here fails or vetoes a sync.
#   - a settings read that fails (not "no row") deploys nothing: never blind;
#   - a red npm test REFUSES the deploy with one alert per console-ui sha naming
#     the failing tests, a log line naming the failing files, and the same sha
#     is re-tested at most CONSOLE_PAGES_RED_TRIES times;
#   - a run that does not deploy while main's oldest undeployed console-ui
#     commit is CONSOLE_PAGES_STALE_ALERT_H hours old raises console-pages-stale;
#   - a failed upload leaves the row unstamped, so the next sync retries;
#   - a 200 from an anonymous probe is a critical: the session gate is open.
# The API token lives only in the deploy subshell's env, and the deploy log is
# scrubbed of it before it reaches logs/.
set -uo pipefail
H="${HARNESS:-/root/harness}"
CO="${HARNESS_CHECKOUT:-/root/harness-checkout}"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }; HENV=$(harness_env_dir "$H")
CFENV="$HENV/cloudflare.env"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
JC="$H/bin/jobs-client.sh"
LA="$H/bin/lane-alert.sh"
SD="$H/state/console-pages-deploy"
log() { echo "$(STAMP) console-pages: $*"; }
alert() { [ -x "$LA" ] && "$LA" "$@" >/dev/null 2>&1 || true; }

# Not the hub, or nothing to deploy: silent, before any knob read or network call.
[ -f "$CFENV" ] && [ -d "$CO/console-ui" ] && [ -e "$CO/.git" ] || exit 0

. "$H/bin/lib/console-pages.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/console-pages.sh" 2>/dev/null \
  || { log "bin/lib/console-pages.sh missing — not deploying"; exit 0; }

# cp_knob <ENV> <env value> <default> — env first (fleet-propagate's
# lane_env_apply exports the settings row into it), then the same row read
# directly for the callers that are not that lane, then the code default. A
# non-numeric value falls through, never clamps.
cp_knob() {
  local v="$2"
  case "$v" in ''|*[!0-9]*) v="" ;; esac
  if [ -z "$v" ] && [ -x "$JC" ]; then
    v=$("$JC" setting-get "lane.fleet-propagate.$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" 2>/dev/null | tr -d '[:space:]')
    case "$v" in ''|*[!0-9]*) v="" ;; esac
  fi
  printf '%s\n' "${v:-$3}"
}
ON=$(cp_knob CONSOLE_PAGES_DEPLOY "${CONSOLE_PAGES_DEPLOY:-}" 1)
[ "$ON" = 0 ] && { log "CONSOLE_PAGES_DEPLOY=0 — off"; exit 0; }
TRIES=$(cp_knob CONSOLE_PAGES_RED_TRIES "${CONSOLE_PAGES_RED_TRIES:-}" 2)
# Seconds between probe rounds: a test seam, env only.
PW="${CONSOLE_PAGES_PROBE_WAIT_S:-10}"
case "$PW" in ''|*[!0-9]*) PW=10 ;; esac

mkdir -p "$SD" "$H/locks" "$H/logs"
# Dedupe, never a queue: a deploy already running owns this sha.
exec 5>"$H/locks/console-pages-deploy.lock"
flock -n 5 || exit 0
# A run the outer timeout killed can leave its scratch; the lock says none is live.
for old in "$H"/state/console-snap.*; do
  case "$old" in "$H/state/console-snap."?*) [ -d "$old" ] && rm -rf -- "$old" ;; esac
done

# DEPLOY ONLY FROM MAIN. The hub checkout tracks main; one parked on a side
# branch (a hand test, a stuck rebase) must never ship that branch's console.
CO_BR=$(git -C "$CO" symbolic-ref --short -q HEAD 2>/dev/null)
[ "$CO_BR" = main ] || { log "checkout is not on main (${CO_BR:-detached}) — not deploying"; exit 0; }
SNAP=$(git -C "$CO" rev-parse HEAD 2>/dev/null) || exit 0
CSHA=$(console_pages_want "$CO" "$SNAP") || exit 0
[ -n "$CSHA" ] || exit 0
C7=${CSHA:0:7}

[ -x "$JC" ] || { log "no jobs-client — settings read failed — not deploying blind"; exit 0; }
LAST=$("$JC" setting-get "$CONSOLE_PAGES_SHA_KEY" 2>/dev/null); LRC=$?
LAST=$(printf '%s' "$LAST" | tr -d '[:space:]')
case "$LRC" in
  0) [ "$LAST" = "$CSHA" ] && exit 0
     # A newer hand deploy is not undone. "none" is not a commit, so it deploys.
     git -C "$CO" merge-base --is-ancestor "$CSHA" "$LAST" 2>/dev/null && exit 0 ;;
  2) LAST= ;;
  *) log "settings read failed (rc=$LRC) — not deploying blind"; exit 0 ;;
esac
L7=${LAST:0:7}; [ -n "$L7" ] || L7='(none)'

# >>> stale alert (BH-9115)
# cp_stale_check <why> — called on each exit that does not deploy. The age is
# the committer time of main's oldest first-parent console-ui commit after the
# deployed one (the wanted commit's own when the row is no commit). At or over
# the knob, ONE warn alert under a fixed id: lane-alert keeps it at one while open.
cp_stale_check() {
  local sh ref k=unknown now age
  # Fallback 24 is the documented fallback of row lane.fleet-propagate.console_pages_stale_alert_h.
  sh=$(cp_knob CONSOLE_PAGES_STALE_ALERT_H "${CONSOLE_PAGES_STALE_ALERT_H:-}" 24)
  [ "$sh" -gt 0 ] 2>/dev/null || return 0
  ref=
  if [ -n "$LAST" ] && git -C "$CO" cat-file -e "$LAST^{commit}" 2>/dev/null; then
    local undep
    undep=$(git -C "$CO" rev-list --first-parent --reverse "$LAST..$SNAP" -- console-ui 2>/dev/null)
    if [ -n "$undep" ]; then
      k=$(printf '%s\n' "$undep" | grep -c .)
      ref=$(git -C "$CO" log -1 --format=%ct "${undep%%$'\n'*}" 2>/dev/null)
    fi
  fi
  [ -n "$ref" ] || ref=$(git -C "$CO" log -1 --format=%ct "$CSHA" 2>/dev/null)
  case "$ref" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s); age=$((now - ref))
  [ "$age" -ge $((sh * 3600)) ] || return 0
  alert --severity warn --id console-pages-stale fleet-propagate "[$(hostname)] Mission Control not deployed for $((age / 3600))h: Pages is on $L7, main's console-ui is at $C7 ($k undeployed console-ui commits); last reason: $1. See logs/console-pages-deploy.log"
}
# <<< stale alert

# The open per-sha red alert id is a settings row, not a state/ file (BH-4159).
# "none" or no row: no red alert is open.
RED_ID_KEY=deploy.console-ui.open_red_id
cp_red_id() {
  local v
  v=$("$JC" setting-get "$RED_ID_KEY" 2>/dev/null | tr -d '[:space:]')
  case "$v" in console-pages-deploy-red:*) printf '%s\n' "$v" ;; esac
}

# The red memo holds "<count> <lane sha>": the lane sha is main's last commit
# touching this deployer or its lib. A memo from other lane code is stale: a
# fix to the lane does not touch console-ui, so the parked sha would stay
# parked and the fix would never run (BH-9115). It counts as 0, and the next
# red run rewrites it.
RM="$SD/red-$CSHA"
LANE_SHA=$(git -C "$CO" log -1 --format=%H "$SNAP" -- bin/console-pages-deploy.sh bin/lib/console-pages.sh 2>/dev/null)
n=; ml=; [ -f "$RM" ] && read -r n ml < "$RM"
case "$n" in ''|*[!0-9]*) n=0 ;; esac
if [ "$n" -gt 0 ] && [ "$ml" != "$LANE_SHA" ]; then
  m7=${ml:0:7}; l7=${LANE_SHA:0:7}
  log "red memo at $C7 is from lane code ${m7:-(none)}, the lane is now at ${l7:-(none)} — re-testing"
  n=0
fi
if [ "$TRIES" -gt 0 ] && [ "$n" -ge "$TRIES" ]; then
  log "npm test was red $n time(s) at $C7 — not re-running until a new console-ui commit"
  cp_stale_check "npm test red $n time(s) at $C7, parked until a new console-ui commit"
  exit 0
fi

D=$(mktemp -d "$H/state/console-snap.XXXXXX") || exit 0
trap 'case "$D" in "$H/state/console-snap."?*) rm -rf -- "$D" ;; esac' EXIT
trap 'exit 143' TERM INT
# Every path console-ui suites read, each only if this commit has it: git
# archive fails on a pathspec the tree does not hold (BH-9115).
SP=()
for p in console-ui worker catalog bin tests; do
  git -C "$CO" cat-file -e "$SNAP:$p" 2>/dev/null && SP+=("$p")
done
git -C "$CO" archive "$SNAP" "${SP[@]}" | tar -x -C "$D"
ps=("${PIPESTATUS[@]}")
[ "${ps[0]}" = 0 ] && [ "${ps[1]}" = 0 ] || { log "snapshot of ${SNAP:0:7} failed (git archive rc=${ps[0]}, tar rc=${ps[1]}) — not deploying"; cp_stale_check "snapshot of ${SNAP:0:7} failed"; exit 0; }
cd "$D/console-ui" || exit 0

if ! timeout 600 npm ci --no-audit --no-fund </dev/null >"$D/ci.log" 2>&1; then
  alert --severity warn --id console-pages-deploy-build fleet-propagate "[$(hostname)] console-ui npm ci failed at $C7 — Pages NOT deployed, live console stays on $L7 (next sync retries)"
  log "npm ci failed at $C7"; cp_stale_check "npm ci failed at $C7"; exit 0
fi

if ! timeout 900 npm test </dev/null >"$D/test.log" 2>&1; then
  # >>> red test names (BH-4940)
  # The failing test names, not the per-file wrappers node --test adds around
  # them; the file names only when nothing else failed (a file that did not load).
  # Each name carries its test file as " [tests/<file>]": from the first YAML
  # `location:` after its `not ok` (Node 22 TAP has no per-file wrapper), else
  # from the enclosing `# Subtest: tests/<file>` wrapper (Node 20).
  NAMES=$(awk -v q="'" '
    /^[[:space:]]*# Subtest: / {
      pend = 0; s = $0; sub(/^[[:space:]]*# Subtest: /, "", s)
      if (s ~ /(^|\/)tests\/[^ ]*\.test\.js$/) { sub(/.*\//, "", s); wf = "tests/" s }
      next
    }
    /^[[:space:]]*(not )?ok [0-9]+ - / {
      pend = 0; s = $0; sub(/^[[:space:]]*(not )?ok [0-9]+ - /, "", s)
      if (s ~ /(^|\/)tests\/[^ ]*\.test\.js$/) { wf = ""; if ($0 ~ /^[[:space:]]*not ok/) f[++nf] = s }
      else if ($0 ~ /^[[:space:]]*not ok/ && nn < 5) { t[++nn] = s; tf[nn] = wf; pend = nn }
      next
    }
    pend && /^[[:space:]]*location: / {
      l = $0; sub(/^[[:space:]]*location: /, "", l); gsub(q, "", l); sub(/:[0-9]+:[0-9]+[[:space:]]*$/, "", l)
      if (l ~ /\.test\.js$/) { sub(/.*\//, "", l); tf[pend] = "tests/" l }
      pend = 0
    }
    END {
      if (nn == 0) for (i = 1; i <= nf && i <= 5; i++) t[++nn] = f[i]
      for (i = 1; i <= nn; i++) printf "%s%s%s", (i > 1 ? "; " : ""), t[i], (tf[i] != "" ? " [" tf[i] "]" : "")
    }' "$D/test.log")
  # <<< red test names
  # >>> red test files (BH-9115)
  # Every distinct test file with a failing test, in order of first failure:
  # a `not ok N - tests/<file>` (a file that did not load, or the Node 20
  # per-file wrapper, which fails when any of its tests fail), or the first
  # YAML `location:` in a test file after any other `not ok` (Node 22).
  # The first RFMAX are named, then " (+k more)".
  # Fallback 20 is the documented fallback of row lane.fleet-propagate.console_pages_red_files_max.
  RFMAX=$(cp_knob CONSOLE_PAGES_RED_FILES_MAX "${CONSOLE_PAGES_RED_FILES_MAX:-}" 20)
  [ "$RFMAX" -gt 0 ] 2>/dev/null || RFMAX=20
  FL=$(awk -v q="'" '
    function add(x) { if (!(x in seen)) { seen[x] = 1; print x } }
    /^[[:space:]]*# Subtest: / { pend = 0; next }
    /^[[:space:]]*(not )?ok [0-9]+ - / {
      pend = 0; s = $0; sub(/^[[:space:]]*(not )?ok [0-9]+ - /, "", s)
      if ($0 !~ /^[[:space:]]*not ok/) next
      if (s ~ /(^|\/)tests\/[^ ]*\.test\.js$/) { sub(/.*\//, "", s); add("tests/" s) } else pend = 1
      next
    }
    pend && /^[[:space:]]*location: / {
      l = $0; sub(/^[[:space:]]*location: /, "", l); gsub(q, "", l); sub(/:[0-9]+:[0-9]+[[:space:]]*$/, "", l)
      if (l ~ /\.test\.js$/) { sub(/.*\//, "", l); add("tests/" l) }
      pend = 0
    }' "$D/test.log")
  NFILES=$(printf '%s' "$FL" | grep -c .)
  FILES=$(printf '%s\n' "$FL" | grep . | head -n "$RFMAX" | paste -sd, - | sed 's/,/, /g')
  [ "$NFILES" -gt "$RFMAX" ] && FILES="$FILES (+$((NFILES - RFMAX)) more)"
  # <<< red test files
  NF_=$(sed -n 's/^# fail //p' "$D/test.log" | tail -1)
  NV=$(node --version 2>/dev/null); NV=${NV:-unknown}
  SINCE=
  if [ -n "$LAST" ] && git -C "$CO" cat-file -e "$LAST^{commit}" 2>/dev/null; then
    SINCE=$(git -C "$CO" log -1 --format=%cs "$LAST" 2>/dev/null)
  fi
  SINCE=${SINCE:-unknown (no deploy record)}
  cp "$D/test.log" "$H/logs/console-pages-deploy-test-$C7.log"
  # One alert per console-ui sha: a fixed id counted each new red sha as a
  # repeat of the first and never sent it. The id is written to the settings
  # row before the alert, so a green run can always resolve it.
  RID="console-pages-deploy-red:$C7"
  OLD=$(cp_red_id)
  "$JC" setting-set "$RED_ID_KEY" "$RID" "red at $C7 on $(hostname)" >/dev/null 2>&1 \
    || log "could not write settings $RED_ID_KEY=$RID — a green run cannot resolve that alert by the row"
  [ -n "$OLD" ] && [ "$OLD" != "$RID" ] && alert --resolve --id "$OLD" fleet-propagate "superseded by a red run at $C7"
  alert --severity warn --id "$RID" fleet-propagate "[$(hostname)] console not deployed since $SINCE: ${NF_:-?} tests red at $C7 (node $NV; $NAMES) — Pages deploy REFUSED, live console stays on $L7 (logs/console-pages-deploy-test-$C7.log)"
  echo "$((n+1)) $LANE_SHA" > "$RM"
  log "npm test red at $C7 (try $((n+1)), node $NV): ${NF_:-?} failing in $NFILES file(s): ${FILES:-none named} — not deploying"
  cp_stale_check "npm test red at $C7 (${NF_:-?} failing)"
  exit 0
fi
RID=$(cp_red_id)
if [ -n "$RID" ]; then
  alert --resolve --id "$RID" fleet-propagate "console-ui npm test green at $C7"
  "$JC" setting-set "$RED_ID_KEY" none "green at $C7 on $(hostname)" >/dev/null 2>&1
fi
# The fixed id that BH-9115 replaced: still open on the hub until a green run.
alert --resolve --id console-pages-deploy-red fleet-propagate "console-ui npm test green at $C7"
rm -f "$RM"

if ! timeout 300 npm run build </dev/null >"$D/build.log" 2>&1; then
  alert --severity warn --id console-pages-deploy-build fleet-propagate "[$(hostname)] console-ui vite build failed at $C7 — Pages NOT deployed, live console stays on $L7 (next sync retries)"
  log "vite build failed at $C7"; cp_stale_check "vite build failed at $C7"; exit 0
fi
alert --resolve --id console-pages-deploy-build fleet-propagate "console-ui build green at $C7"

# The token only ever lives in this subshell's env.
PROJECT=$(console_pages_project)
( set -a; . "$CFENV"; set +a
  acct=$(console_pages_account_id "$D") && [ -n "$acct" ] && export CLOUDFLARE_ACCOUNT_ID="$acct"
  timeout 600 npx --yes wrangler@3 pages deploy dist --project-name "$PROJECT" --branch main \
    --commit-hash "$CSHA" --commit-message "harness-sync $C7" </dev/null ) >"$D/deploy.log" 2>&1
DRC=$?
# Scrub the literal token and any Bearer value before anything reads the log.
# The token goes through the environment, never argv.
CP_TOK=$( set -a; . "$CFENV" >/dev/null 2>&1; printf '%s' "${CLOUDFLARE_API_TOKEN:-}" )
CP_TOK="$CP_TOK" awk '{t=ENVIRON["CP_TOK"]; if (t!="") while ((i=index($0,t))>0) $0=substr($0,1,i-1) "***" substr($0,i+length(t)); gsub(/Bearer[ \t]+[^ \t]+/,"Bearer ***"); print}' "$D/deploy.log"
unset CP_TOK

if [ "$DRC" != 0 ]; then
  alert --severity warn --id console-pages-deploy-failed fleet-propagate "[$(hostname)] wrangler pages deploy FAILED at $C7 (rc=$DRC) — LIVE CONSOLE IS STALE at $L7; see logs/console-pages-deploy.log"
  log "wrangler pages deploy failed at $C7 (rc=$DRC)"; cp_stale_check "wrangler pages deploy failed at $C7 (rc=$DRC)"; exit 0
fi
if grep -q 'Uploading Functions bundle' "$D/deploy.log"; then
  alert --resolve --id console-pages-deploy-failed fleet-propagate "Pages deploy green at $C7"
else
  # The upload is live, so it is stamped; the alert stays open until a good deploy.
  alert --severity warn --id console-pages-deploy-failed fleet-propagate "[$(hostname)] wrangler pages deploy at $C7 deployed $C7 but no 'Uploading Functions bundle' — /api/* will 404"
fi

# Write, then tell.
if "$JC" setting-set "$CONSOLE_PAGES_SHA_KEY" "$CSHA" "pages deploy by $(hostname) at $(STAMP)" >/dev/null 2>&1; then
  alert --resolve --id console-pages-deploy-stamp fleet-propagate "settings $CONSOLE_PAGES_SHA_KEY written at $C7"
  alert --resolve --id console-pages-stale fleet-propagate "console-ui deployed at $C7"
else
  alert --severity warn --id console-pages-deploy-stamp fleet-propagate "[$(hostname)] deployed $C7 but could not write settings $CONSOLE_PAGES_SHA_KEY — the next sync redeploys the same sha"
fi
log "console-ui deployed at $C7 (snapshot ${SNAP:0:7}, was $L7)"

# Anonymous probes: the session gate must answer 403 on both.
URL=$(console_pages_url)
c1=000; c2=000
for r in 1 2 3 4 5 6; do
  [ "$r" = 1 ] || sleep "$PW"
  c1=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$URL/api/coord/jobs" </dev/null); c1=${c1:-000}
  c2=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$URL/api/ideas/list" </dev/null); c2=${c2:-000}
  case "$c1" in 403|200|404|503) case "$c2" in 403|200|404|503) break ;; esac ;; esac
done
if [ "$c1" = 200 ] || [ "$c2" = 200 ]; then
  p=/api/coord/jobs; [ "$c1" = 200 ] || p=/api/ideas/list
  alert --critical --id console-pages-failopen fleet-propagate "[$(hostname)] SECURITY: $URL$p answered 200 to an anonymous caller at $C7 — the session gate is not enforced"
  log "probes $c1/$c2 — SECURITY: anonymous 200"
elif [ "$c1" = 403 ] && [ "$c2" = 403 ]; then
  alert --resolve --id console-pages-probe fleet-propagate "Pages probes 403/403 at $C7"
  alert --resolve --id console-pages-failopen fleet-propagate "Pages probes 403/403 at $C7"
  log "probes 403/403"
else
  alert --severity warn --id console-pages-probe fleet-propagate "[$(hostname)] Pages probes at $C7: /api/coord/jobs=$c1 /api/ideas/list=$c2 (want 403/403; 404 = Functions bundle missing, 503 = CONSOLE_DB/HARNESS_SECRET binding missing — skills/console-deploy step 1)"
  log "probes $c1/$c2"
fi

# >>> post-merge QA (BH-5909)
# Keep a copy of the dist/ just shipped and launch bin/console-postmerge-qa.sh
# on it, detached in its own session with its own timeout: a slow drive never
# holds this deploy, and this deploy's timeout never cuts a drive. The copy is
# made under a temp name and renamed, so the QA run never reads a half copy.
PQ=$(cp_knob CONSOLE_POSTMERGE_QA "${CONSOLE_POSTMERGE_QA:-}" 0)
if [ "$PQ" = 1 ] && [ -x "$H/bin/console-postmerge-qa.sh" ]; then
  PQD="$H/state/console-postmerge-qa"; PQT="$PQD/dist-$CSHA.tmp.$$"
  pq_rm() { case "$1" in "$H/state/console-postmerge-qa/dist-"?*) rm -rf -- "$1" ;; esac; }
  if mkdir -p "$PQD" && cp -RP -- "$D/console-ui/dist" "$PQT" && pq_rm "$PQD/dist-$CSHA" && mv -- "$PQT" "$PQD/dist-$CSHA"; then
    PTO=$(cp_knob CONSOLE_POSTMERGE_QA_TIMEOUT_S "${CONSOLE_POSTMERGE_QA_TIMEOUT_S:-}" 900)
    if [ "$PTO" -lt 120 ] || [ "$PTO" -gt 3600 ]; then log "CONSOLE_POSTMERGE_QA_TIMEOUT_S=$PTO is outside 120..3600 — using 900"; PTO=900; fi
    pre=; command -v setsid >/dev/null 2>&1 && pre=setsid
    ( HARNESS="$H" HARNESS_CHECKOUT="$CO" HARNESS_ENV_DIR="$HENV" $pre timeout -k 30 "$PTO" \
        "$H/bin/console-postmerge-qa.sh" "$CSHA" "$PQD/dist-$CSHA" </dev/null \
        >>"$H/logs/console-postmerge-qa.log" 2>&1 5>&- 9>&- 8>&- 7>&- 6>&- & ) || true
    log "post-merge QA launched at $C7"
  else
    pq_rm "$PQT"
    log "post-merge QA not launched at $C7: the copy of dist/ failed"
  fi
fi
# <<< post-merge QA
exit 0
