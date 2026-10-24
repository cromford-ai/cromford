#!/bin/bash
# shellcheck shell=bash
# bin/lib/console-preview.sh — the per-PR Cloudflare Pages preview of console-ui:
# its branch alias, its URL, whether a diff reaches console-ui/, and the PR
# comment marker that records which head was deployed. Sourced, never executed.
#
# WHY. console-ui/ reached Pages only after merge (bin/console-pages-deploy.sh),
# so the preview QA stage had no URL to drive and the Mission Control redesign
# (#4990..#4993) merged with no browser QA at all. bin/console-preview-deploy.sh
# deploys each console PR head under its branch alias and posts the marker.
# Slice 2 (#6067, bin/lib/console-qa-gate.sh) reads the QA result back, and
# trusts it only from a writer or the harness App; this slice reads it only to
# skip a head that is already deployed.
#
# THE MARKER, one per deployed head, in a PR comment:
#   <!-- console-preview sha=<40 hex> url=<preview url> -->
# It is the durable "this head is deployed" record. A reader never trusts the
# url in it: the URL is always recomputed from the branch (cpv_url), so a
# comment someone else wrote cannot send QA, or the QA secret, elsewhere.
#
# FAILURE. Every function returns non-zero and prints nothing when it has no
# answer. cpv_touches_console and cpv_comments tell "no" (1, or 44) from
# "could not read" (2, or 75): an unread diff or thread is never a "no".
# The root is ${HARNESS:-${H:-}} only (D43); this file reads none of it.

_CPV_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
declare -F console_pages_url >/dev/null || . "$_CPV_LIB/console-pages.sh" || return 1
declare -F gh_rest >/dev/null || . "$_CPV_LIB/gh-rest.sh" || return 1

# cpv_alias <branch> — the alias Pages gives a --branch deploy: lower case,
# every char outside [a-z0-9-] becomes "-", cut to 28 chars, no trailing "-".
# `main` (the production branch), `postmerge-qa` (the alias
# bin/console-postmerge-qa.sh deploys the shipped build to) and an all-dash
# name are refused.
cpv_alias() {
  local a
  a=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')
  a=${a:0:28}
  while [ "${a%-}" != "$a" ]; do a=${a%-}; done
  case "$a" in ''|main|postmerge-qa) return 1 ;; esac
  # <8 hex>.<project>.pages.dev is a production deployment's own URL, so an
  # alias of that shape gets a prefix (console-ui/functions/qa-login refuses it).
  [[ "$a" =~ ^[0-9a-f]{8}$ ]] && a="br-$a"
  printf '%s\n' "$a"
}

# cpv_url <alias> — https://<alias>.<the console Pages host>. The host is
# console_pages_url's, never a literal here.
cpv_url() {
  local host
  [ -n "${1:-}" ] || return 1
  host=$(console_pages_url) || return 1
  host=${host#https://}; host=${host#http://}
  [ -n "$host" ] || return 1
  printf 'https://%s.%s\n' "$1" "$host"
}

# cpv_touches_console <git-dir> <base> <head> — 0 when base...head changes a
# path under console-ui/, 1 when it does not, 2 when the diff did not read.
cpv_touches_console() {
  local f
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 2
  f=$(git -C "$1" diff --name-only "$2...$3" 2>/dev/null) || return 2
  grep -q '^console-ui/' <<<"$f" && return 0
  return 1
}

# cpv_comments <slug> <num> <out> — every comment on issue/PR <num> as ONE JSON
# array in <out>. Pages of 100, at most CPV_COMMENT_PAGES (10) of them. rc 0;
# 44 when GitHub says 404; 75 when any page did not read, or the last page
# allowed was still full (a thread we did not read to the end is not read).
cpv_comments() {
  local slug="${1:-}" n="${2:-}" out="${3:-}" max="${CPV_COMMENT_PAGES:-10}" p=1 rc tmp
  [ -n "$out" ] || return 75
  case "$max" in ''|*[!0-9]*|0) max=10 ;; esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/cpv.XXXXXX") || return 75
  echo '[]' > "$out"
  while :; do
    rc=0
    gh_rest GET "repos/$slug/issues/$n/comments?per_page=100&page=$p" > "$tmp" || rc=$?
    if [ "$rc" != 0 ]; then rm -f "$tmp"; return "$rc"; fi
    jq -e 'type == "array"' "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 75; }
    jq -s '.[0] + .[1]' "$out" "$tmp" > "$out.n" 2>/dev/null && mv -f "$out.n" "$out" || { rm -f "$tmp" "$out.n"; return 75; }
    [ "$(jq length "$tmp")" -ge 100 ] || break
    [ "$p" -lt "$max" ] || { rm -f "$tmp"; return 75; }
    p=$((p + 1))
  done
  rm -f "$tmp"
  return 0
}

# cpv_marker_seen <comments.json> <sha> <url> — 0 when a comment carries the
# marker for exactly this head AND this url.
cpv_marker_seen() {
  [ -r "${1:-}" ] && [[ "${2:-}" =~ ^[0-9a-f]{40}$ ]] && [ -n "${3:-}" ] || return 1
  jq -e --arg m "<!-- console-preview sha=$2 url=$3 -->" \
    'any(.[]?; (.body // "") | gsub("\r"; "") | split("\n") | any(.[]; . == $m))' "$1" >/dev/null 2>&1
}

# _cpv_uid_pids <uid> — the sorted pids whose real or effective uid is <uid>,
# one per line (nothing when there are none). rc 2 when pgrep is missing.
_cpv_uid_pids() {
  command -v pgrep >/dev/null 2>&1 || return 2
  # pgrep is rc 1 when nothing matches; under pipefail that must not leak out.
  { pgrep -u "$1"; pgrep -U "$1"; true; } 2>/dev/null | sort -un
}

# _cpv_uid_busy <who> <uid> <when> — rc 0 when <uid> has no live process. Else
# rc 125 and one stderr line with the count and the first 5 pids. <when> is
# "before" or "after" the build.
_cpv_uid_busy() {
  local pids k
  pids=$(_cpv_uid_pids "$2") || { echo "cpv_run_unpriv: pgrep is not installed, so the build user cannot be checked" >&2; return 125; }
  [ -n "$pids" ] || return 0
  k=$(wc -l <<<"$pids" | tr -d ' ')
  pids=$(head -n 5 <<<"$pids" | tr '\n' ' '); pids=${pids% }
  if [ "$3" = before ]; then
    echo "cpv_run_unpriv: build user '$1' (uid $2) has $k live process(es) (pid $pids) — no build starts while one is alive" >&2
  else
    echo "cpv_run_unpriv: build user '$1' (uid $2) still has $k process(es) after the build (pid $pids) — the build output is not used" >&2
  fi
  return 125
}

# cpv_run_unpriv <root> <workdir> <timeout> <cmd...> — run <cmd> in <workdir>
# (under <root>) as an unprivileged user, with a clean environment. The PR head
# is code nobody has reviewed yet: its package.json and vite.config.js must not
# run as root beside /etc/harness/env (BH-5909 review). The user is
# CONSOLE_PREVIEW_BUILD_USER (default nobody); <root> is handed to it, and the
# env carries PATH and a HOME, npm cache and TMPDIR under <root>, nothing else.
# NOTHING THE COMMAND STARTS OUTLIVES IT. <cmd> runs in its own PID namespace
# (unshare --pid --fork --kill-child --mount-proc) under `timeout`, which is
# the namespace's PID 1. When PID 1 exits, the command ended or timed out, the
# kernel kills every process left in the namespace: setsid, nohup and a
# double fork cannot leave it. An outer `timeout` (<timeout> + 30 s) is the
# backstop. For a real build user, `setpriv` changes the child's credentials,
# so the kernel clears the PR_SET_PDEATHSIG that --kill-child set. A kill of
# unshare (the outer timeout, or lane-reaper.sh) then leaves the namespace
# alive until the inner `timeout -k 5 <timeout>` ends it: at most <timeout> +
# 5 s. The namespace still holds every process, and the next run's preflight
# refuses while one is alive. In self mode with no setpriv, --kill-child does
# take PID 1 and the namespace.
# The build user must have no live process before the run (one could write
# the build tree) and none after it (root then reads dist/ from that tree).
# rc 125, with the reason on stderr, when the build cannot be run isolated:
# not root, no setpriv, no such user, a uid of 0, a <root> the user cannot
# write, a box that cannot make a PID namespace, no pgrep, or a live process
# of the build user before or after the run. Otherwise the command's rc (124
# on a timeout), with a command rc of 125 returned as 1.
# The ONE other mode is CONSOLE_PREVIEW_BUILD_USER=self, honoured only under
# HARNESS_TEST_SANDBOX=1: the suites run as themselves with the same clean env.
# It tries the PID namespace as root, then inside a user namespace, and runs
# without one (one stderr line) when neither works. It checks live processes
# of the uid CPV_TEST_UID, and of no uid when that is unset (the runner's own
# uid always has live processes).
cpv_run_unpriv() {
  local root="${1:-}" wd="${2:-}" to="${3:-}" who="${CONSOLE_PREVIEW_BUILD_USER:-nobody}" uid gid chk="" ns=()
  shift 3 || return 125
  [ -d "$root" ] && [ -d "$wd" ] && [ "$#" -gt 0 ] || { echo "cpv_run_unpriv: bad arguments" >&2; return 125; }
  case "$to" in ''|*[!0-9]*) echo "cpv_run_unpriv: bad arguments" >&2; return 125 ;; esac
  mkdir -p "$root/.cpv-home" "$root/.cpv-tmp" "$root/.cpv-npm" || return 125
  local cenv=(env -i PATH="$PATH" HOME="$root/.cpv-home" TMPDIR="$root/.cpv-tmp"
              npm_config_cache="$root/.cpv-npm" LANG=C.UTF-8 CI=1)
  local pidns=(unshare --pid --fork --kill-child --mount-proc --)
  if [ "$who" = self ]; then
    [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] \
      || { echo "cpv_run_unpriv: CONSOLE_PREVIEW_BUILD_USER=self is for the test sandbox only" >&2; return 125; }
    chk=${CPV_TEST_UID:-}
    case "$chk" in *[!0-9]*) echo "cpv_run_unpriv: CPV_TEST_UID '$chk' is not a uid" >&2; return 125 ;; esac
    if "${pidns[@]}" true >/dev/null 2>&1; then ns=("${pidns[@]}")
    elif unshare --user --map-root-user --pid --fork --kill-child --mount-proc -- true >/dev/null 2>&1; then
      ns=(unshare --user --map-root-user --pid --fork --kill-child --mount-proc --)
    else
      echo "cpv_run_unpriv: self mode without a PID namespace (test sandbox)" >&2
    fi
    if [ -n "$chk" ]; then _cpv_uid_busy "$who" "$chk" before || return; fi
    ( cd "$wd" && timeout -k 10 "$((to + 30))" "${ns[@]}" "${cenv[@]}" timeout -k 5 "$to" "$@" </dev/null )
  else
    [ "$(id -u)" = 0 ] || { echo "cpv_run_unpriv: not root, so the build cannot drop to '$who'" >&2; return 125; }
    command -v setpriv >/dev/null 2>&1 || { echo "cpv_run_unpriv: setpriv is not installed" >&2; return 125; }
    uid=$(id -u "$who" 2>/dev/null) && gid=$(id -g "$who" 2>/dev/null) \
      || { echo "cpv_run_unpriv: there is no user '$who'" >&2; return 125; }
    [ "$uid" != 0 ] || { echo "cpv_run_unpriv: user '$who' is uid 0" >&2; return 125; }
    chk=$uid
    command -v unshare >/dev/null 2>&1 && "${pidns[@]}" true >/dev/null 2>&1 \
      || { echo "cpv_run_unpriv: this box cannot start a PID namespace (unshare --pid refused), so the build cannot be isolated" >&2; return 125; }
    ns=("${pidns[@]}")
    _cpv_uid_busy "$who" "$chk" before || return
    chown -R "$uid:$gid" "$root" || { echo "cpv_run_unpriv: could not hand $root to '$who'" >&2; return 125; }
    setpriv --reuid="$uid" --regid="$gid" --clear-groups test -w "$wd" 2>/dev/null \
      || { echo "cpv_run_unpriv: '$who' cannot write $wd" >&2; return 125; }
    ( cd "$wd" && timeout -k 10 "$((to + 30))" "${ns[@]}" setpriv --reuid="$uid" --regid="$gid" --clear-groups \
        "${cenv[@]}" timeout -k 5 "$to" "$@" </dev/null )
  fi
  local rc=$?
  # 125 is this function's box-fault code. The PR head picks the command's rc
  # ("build": "exit 125"), so a 125 from the command is a head failure, never
  # a box fault: it must not stop the lane or skip the attempt charge.
  [ "$rc" != 125 ] || rc=1
  if [ -n "$chk" ]; then _cpv_uid_busy "$who" "$chk" after || return; fi
  return "$rc"
}

# cpv_copy_dist <from-dist> <to-dist> — copy a build output that an
# unprivileged user wrote into a root-owned tree, then refuse it (rc 1, the
# reason on stderr) if the COPY holds anything but plain files and dirs. A
# symlink in dist would make a root wrangler upload whatever it points at.
# The check runs on the copy, so the build user cannot swap a file after it.
cpv_copy_dist() {
  local from="${1:-}" to="${2:-}" odd stripped=""
  [ -d "$from" ] && [ ! -L "$from" ] || { echo "cpv_copy_dist: no dist directory" >&2; return 1; }
  case "$to" in */dist) ;; *) echo "cpv_copy_dist: target '$to' is not a dist path" >&2; return 1 ;; esac
  rm -rf -- "$to" && cp -RP -- "$from" "$to" || { echo "cpv_copy_dist: copy failed" >&2; return 1; }
  # Pages runs dist/_worker.js (a file or a directory) as the site's server code
  # in place of functions/, and dist/_routes.json decides which paths reach it.
  # A PR's build can emit either from vite.config.js or public/, so neither, nor
  # a dist/functions/, is ever deployed: the preview runs main's Functions only.
  for odd in _worker.js _routes.json functions; do
    if [ -e "$to/$odd" ] || [ -L "$to/$odd" ]; then rm -rf -- "${to:?}/$odd"; stripped="$stripped $odd"; fi
  done
  [ -z "$stripped" ] || echo "cpv_copy_dist: stripped from the PR build output:$stripped" >&2
  odd=$(find "$to" ! -type f ! -type d -print -quit 2>/dev/null)
  [ -z "$odd" ] || { echo "cpv_copy_dist: dist holds a non-regular file (${odd#"$to"/})" >&2; rm -rf -- "$to"; return 1; }
  return 0
}

# cpv_coord_writes <git-dir> <sha> <tree> — render the coord proxy's fragment
# write table (BH-6487) into a deploy tree that holds only <sha>'s
# console-ui/functions and console-ui/src. The proxy imports `#coord-writes`,
# which needs console-ui/package.json and the rendered
# functions/_lib/coord-writes.gen.js in the tree, or the Functions bundle
# fails. A <sha> with no console-ui/scripts/coord-writes-build.mjs predates the
# split: rc 0, the tree is not touched. Else rc 0 with the gen file in place,
# or rc 1 and one stderr line that says why.
cpv_coord_writes() {
  local co="$1" sha="$2" tree="$3" ps rc err
  git -C "$co" cat-file -e "$sha:console-ui/scripts/coord-writes-build.mjs" 2>/dev/null || return 0
  git -C "$co" archive "$sha" console-ui/package.json console-ui/scripts 2>/dev/null | tar -x -C "$tree" 2>/dev/null
  ps=("${PIPESTATUS[@]}")
  [ "${ps[0]}" = 0 ] && [ "${ps[1]}" = 0 ] \
    || { echo "package.json and scripts/ did not copy (git archive rc=${ps[0]}, tar rc=${ps[1]})" >&2; return 1; }
  err=$(cd "$tree/console-ui" && timeout 60 node scripts/coord-writes-build.mjs 2>&1 >/dev/null); rc=$?
  [ "$rc" = 0 ] || { echo "render rc=$rc: $(printf '%s\n' "$err" | tail -n 1 | cut -c1-200)" >&2; return 1; }
  [ -f "$tree/console-ui/functions/_lib/coord-writes.gen.js" ] || { echo "the render wrote no coord-writes.gen.js" >&2; return 1; }
  return 0
}

# ── THE BUILD AND THE DEPLOY OF ONE HEAD (BH-8030) ───────────────────────────
# One body for both places it runs: the hub lane (bin/console-preview-deploy.sh
# deploy_one) and a Fly pool machine (bin/lib/console-preview-job.sh, a CP-*
# row). The caller sets these globals and defines `log <text>`:
#   CPV_CO        the git dir that holds <sha> and origin/main
#   CPV_BT        where the unprivileged build tree console-preview-build.* is made
#   CPV_SNAP_DIR  where the root-owned deploy tree console-preview-snap.* is made
#   CPV_CFENV     the env file with CLOUDFLARE_API_TOKEN
#   CPV_ACCT      the Cloudflare account id
#   CPV_WRANGLER  the exact wrangler version
#   CPV_TOKV      the API token value, for cpv_scrub
# It sets CPV_B and CPV_D (the two trees: the caller removes them on every
# path), BOX_WHY and BOX_STAGE (build|upload) for rc 3, CPV_HEAD_WHY for rc 1,
# and CPV_STRIPPED (the dist entries cpv_copy_dist removed).

# cpv_scrub <file> — the file with the API token (CPV_TOKV) and any Bearer
# value replaced by ***.
cpv_scrub() { CP_TOK="${CPV_TOKV:-}" awk '{t=ENVIRON["CP_TOK"]; if (t!="") while ((i=index($0,t))>0) $0=substr($0,1,i-1) "***" substr($0,i+length(t)); gsub(/Bearer[ \t]+[^ \t]+/,"Bearer ***"); print}' "$1"; }

# cpv_upload_fault <clean log> <wrangler rc> — prints box | head.
# A 401, 403 or 429 is the box's only after an error word (`HTTP 403`,
# `status: 429`, `Error 401.`), never inside a file name (`dist/403.html`).
# The head patterns read wrangler's error block only (from the first
# `[ERROR]` line on). Wrangler logs `Uploading _headers` and `Uploading
# _redirects` on every deploy before its /deployments POST, so a head pattern
# run over the whole log would charge any unknown later failure to the head
# (lead review lr-6056-72e007976067). No error block = an unknown fault = box.
cpv_upload_fault() {
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

# cpv_build_deploy <n> <alias> <sha> <url> — rc 0 only on a complete deploy.
#   rc 1  the HEAD's own fault: its npm ci or vite build failed, or its dist was
#         refused (CPV_HEAD_WHY says which). Only this counts toward
#         CONSOLE_PREVIEW_MAX_ATTEMPTS.
#   rc 3  the BOX's fault, not the head's (lead BLOCK at 54f3dfea9): no build
#         dir, a copy that failed, a build that cannot be isolated (rc 125: no
#         setpriv, no build user, a dir it cannot write), main's Functions not
#         copied, a wrangler or Cloudflare error. BOX_WHY says which. It is never
#         charged to a head.
#   An UPLOAD failure is classified from wrangler's own words: only a dist
#   Pages refuses (a file too large, too many files, a bad _headers or
#   _redirects) is the head's (rc 1). Everything else is the box's (rc 3,
#   BOX_STAGE=upload): auth, network, rate, a 5xx, npm's own errors (npm 10
#   prints `npm error code ENOSPC`), a timeout (rc 124), a kill (rc 137) and any
#   error nobody classified (lead BLOCK at 1f9246916).
cpv_build_deploy() {
  local n="$1" alias="$2" sha="$3" url="$4" s7=${3:0:7} drc ps urc=0 brc=0 why
  local co="${CPV_CO:-}" bt="${CPV_BT:-/tmp}" snap="${CPV_SNAP_DIR:-}"
  BOX_STAGE=build; BOX_WHY=""; CPV_HEAD_WHY=""; CPV_STRIPPED=""; CPV_B=""; CPV_D=""
  _cpv_box() { BOX_WHY="$1"; log "#$n $1 at $s7 — not charged to the head; this run stops"; return 3; }
  _cpv_head() { CPV_HEAD_WHY="$1"; log "#$n $1 at $s7 — preview not deployed"; return 1; }
  [ -n "$co" ] && [ -n "$snap" ] && [ -n "${CPV_CFENV:-}" ] || { _cpv_box "the build is not configured (CPV_CO, CPV_SNAP_DIR or CPV_CFENV unset)"; return; }
  # 1. The build: the PR head in its own tree, unprivileged, clean env, no
  #    install scripts. Only its dist's plain files come back.
  CPV_B=$(mktemp -d "$bt/console-preview-build.XXXXXX") || { CPV_B=""; _cpv_box "no build dir under $bt"; return; }
  git -C "$co" archive "$sha" console-ui worker catalog | tar -x -C "$CPV_B"
  ps=("${PIPESTATUS[@]}")
  [ "${ps[0]}" = 0 ] && [ "${ps[1]}" = 0 ] || { _cpv_box "build copy failed (git archive rc=${ps[0]}, tar rc=${ps[1]})"; return; }
  CPV_D=$(mktemp -d "$snap/console-preview-snap.XXXXXX") || { CPV_D=""; _cpv_box "no snapshot dir under $snap"; return; }
  cpv_run_unpriv "$CPV_B" "$CPV_B/console-ui" 600 npm ci --ignore-scripts --no-audit --no-fund >"$CPV_D/ci.log" 2>&1 || urc=$?
  [ "$urc" = 125 ] && { _cpv_box "build not isolated: $(tail -n 1 "$CPV_D/ci.log")"; return; }
  [ "$urc" = 0 ] || { _cpv_head "npm ci failed"; return; }
  cpv_run_unpriv "$CPV_B" "$CPV_B/console-ui" 300 npm run build >"$CPV_D/build.log" 2>&1 || brc=$?
  [ "$brc" = 125 ] && { _cpv_box "build not isolated: $(tail -n 1 "$CPV_D/build.log")"; return; }
  [ "$brc" = 0 ] || { _cpv_head "vite build failed"; return; }
  # 2. The deploy tree: origin/main's functions/ and src/, the PR's dist/ only.
  git -C "$co" archive origin/main console-ui/functions console-ui/src | tar -x -C "$CPV_D"
  ps=("${PIPESTATUS[@]}")
  [ "${ps[0]}" = 0 ] && [ "${ps[1]}" = 0 ] || { _cpv_box "main's functions could not be copied (git archive rc=${ps[0]}, tar rc=${ps[1]})"; return; }
  # BH-6487: the proxy's #coord-writes import needs package.json and the rendered table.
  why=$(cpv_coord_writes "$co" origin/main "$CPV_D" 2>&1) || { _cpv_box "main's coord write table did not render (${why:-no reason})"; return; }
  if ! cpv_copy_dist "$CPV_B/console-ui/dist" "$CPV_D/console-ui/dist" 2>>"$CPV_D/build.log"; then
    CPV_HEAD_WHY="build output refused: $(tail -n 1 "$CPV_D/build.log")"
    log "#$n build output of $s7 refused: $(tail -n 1 "$CPV_D/build.log") — preview not deployed"; return 1
  fi
  if grep -q '^cpv_copy_dist: stripped' "$CPV_D/build.log"; then
    CPV_STRIPPED=$(grep '^cpv_copy_dist: stripped' "$CPV_D/build.log" | tail -n 1 | sed 's/^cpv_copy_dist: stripped from the PR build output://')
    log "#$n $(grep '^cpv_copy_dist: stripped' "$CPV_D/build.log" | tail -n 1 | sed 's/^cpv_copy_dist: //') (Pages would run them as server code; main's Functions deploy instead)"
  fi
  # 3. The upload: pinned wrangler, no npm config from anywhere, pinned registry.
  # The user and global npm configs are two different empty files: npm 10+
  # refuses one path loaded as both ("double-loading config /dev/null").
  : > "$CPV_D/.npmrc-user"; : > "$CPV_D/.npmrc-global"
  ( set -a; . "$CPV_CFENV"; set +a
    export CLOUDFLARE_ACCOUNT_ID="$CPV_ACCT" npm_config_userconfig="$CPV_D/.npmrc-user" npm_config_globalconfig="$CPV_D/.npmrc-global" \
           npm_config_registry=https://registry.npmjs.org/ npm_config_cache="$CPV_D/.npm"
    cd "$CPV_D/console-ui" && timeout 600 npx --yes "wrangler@$CPV_WRANGLER" pages deploy dist --project-name "$(console_pages_project)" \
      --branch "$alias" --commit-hash "$sha" --commit-message "preview PR #$n $s7" </dev/null ) >"$CPV_D/deploy.log" 2>&1
  drc=$?
  cpv_scrub "$CPV_D/deploy.log" > "$CPV_D/deploy.clean"
  tail -n 5 "$CPV_D/deploy.clean" | sed "s/^/  #$n wrangler: /"
  if [ "$drc" != 0 ] || ! grep -q 'Deployment complete' "$CPV_D/deploy.clean"; then
    BOX_STAGE=upload
    why="wrangler rc=$drc: $(grep -iE 'error|✘' "$CPV_D/deploy.clean" | tail -n 1 | cut -c1-200)"
    if [ "$(cpv_upload_fault "$CPV_D/deploy.clean" "$drc")" = head ]; then
      CPV_HEAD_WHY="Pages refused the head's own dist/ ($why)"
      log "#$n preview deploy failed at $s7: $CPV_HEAD_WHY — charged to the head"; return 1
    fi
    _cpv_box "preview deploy failed on the box side ($why) — no comment, the next tick retries"; return
  fi
  log "#$n preview deployed at $s7: $url"
  return 0
}

# ── THE POOL PLACEMENT (BH-8030) ──────────────────────────────────────────────
# With the settings row lane_placement.console-preview-deploy = fly, the hub
# lane queues one pool row per PR head (key CP-<pr>-<head8>-<job>, meta kind
# console_preview) and a Fly pool machine runs cpv_build_deploy
# (bin/lib/console-preview-job.sh). The hub reads the row back. These helpers
# need the jobs client (_jobs_req).

# cpv_pool_key <pr> <sha> <job> — CP-<pr>-<head8>-<job>.
cpv_pool_key() {
  [[ "${1:-}" =~ ^[0-9]+$ && "${2:-}" =~ ^[0-9a-f]{40}$ && "${3:-}" =~ ^[0-9]+$ ]] || return 1
  printf 'CP-%s-%s-%s\n' "$1" "${2:0:8}" "$3"
}

# cpv_pool_row <project> <key> — ONE queue read. rc 0 prints `none`, or
# `<status>\t<age s or ->\t<reason line 1>`. rc 1 when the read failed or the
# body did not parse: a failed read is never `none`.
cpv_pool_row() {
  local resp now
  resp=$(_jobs_req GET "/api/queue?project=$1&key=$2&limit=1") || return 1
  now=${CPV_NOW:-$(date -u +%s)}
  printf '%s' "$resp" | jq -er --argjson now "$now" '
    def age: (. // "") | tostring | sub("\\.[0-9]+Z$"; "Z") | (fromdateiso8601? // null)
      | if . == null then "-" else ($now - .) | tostring end;
    if (.queue | type) != "array" then error("no queue")
    else (.queue[0] // null) | if . == null then "none"
    else [ (.status // ""), (.enqueued_at | age),
           ((.reason // "") | (split("\n")[0] // "") | gsub("[\t\r]"; " ")) ] | join("\t") end end' 2>/dev/null
}
