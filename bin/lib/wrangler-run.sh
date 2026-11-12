#!/bin/bash
# bin/lib/wrangler-run.sh — the one way the hub runs wrangler (BH-9460).
# Sourced, never executed. Callers: bin/harness-sync.sh (d1_exec, the worker
# deploy, the wrangler-install step) and bin/console-pages-deploy.sh.
#
# WHY. On 2026-11-09 a step timeout killed `npx --yes wrangler` while npm was
# installing wrangler into ~/.npm/_npx/<hash>. The cache stayed half-written,
# and each of the next 131 `npx --yes wrangler` calls stopped with `npm error
# code ENOTEMPTY` before wrangler started. npm does not repair that state.
# harness-sync read each failure as "schema.sql statement 1/23 failed against
# D1", although no statement reached D1.
#
# WHAT IT DOES.
#   wrangler_run [--spec <npx-spec>] <timeout_s> <wrangler args...>
#     Runs `timeout <t> npx --yes <spec> <args>`, then prints the combined
#     output on stdout (the caller's redirect is unchanged).
#     - No --spec, and a pinned install (wrangler_install) whose .spec equals
#       the knob: it runs `wrangler@<pinned version>` with npm_config_cache set
#       to that private cache. Otherwise the spec is the knob
#       HARNESS_SYNC_WRANGLER_SPEC (default `wrangler`) on the shared cache.
#     - A TOOL FAILURE (wrangler_tool_code prints a code): it moves the npx
#       cache directory aside and runs the command ONE more time. The retry
#       runs only when wrangler never started, so a D1 statement or a deploy
#       is never sent twice by this helper.
#     - Returns 0 (clean, or healed: one `wrangler-run: npx cache healed`
#       line), WRANGLER_TOOL_RC (87) when the retry also fails as a tool (the
#       code goes to $WRANGLER_TOOL_ERR_FILE), or wrangler's own rc.
#   wrangler_tool_code <outfile>
#     Prints the npm error code (ENOTEMPTY, ENOENT, EINTEGRITY, …) only when
#     the output has `npm error code E…` / `npm ERR! code E…` and NO wrangler
#     start banner (`⛅️ wrangler` or a line `wrangler <digit>…`). An npm line
#     AFTER wrangler started is wrangler's business, not a tool failure.
#   wrangler_tool_code_last — the code the last rc 87 wrote.
#   wrangler_install
#     Installs the knob spec into a PRIVATE cache, state/wrangler-npx/, in its
#     own step and under its own `flock -n`, never inside the deploy step. The
#     install goes to a stage dir; `current` only moves (atomic rename) after
#     the stage holds a verified wrangler package.json. A kill at any point
#     leaves a stage dir, which the next run deletes, and never a live cache.
#     Keeps `current` + the previous version dir (the retention rule).
#
# KNOBS (catalog/lanes.d/fleet-propagate.knobs.d/), each read as env, then
# the settings row lane.fleet-propagate.<lowercase name>, then the code default:
#   HARNESS_SYNC_WRANGLER_SPEC            default `wrangler`
#   HARNESS_SYNC_WRANGLER_INSTALL_RETRY_S default 3600 (0 = retry every run)
#
# The root is ${HARNESS:-${H:-}} and nothing else (D43): with no root,
# wrangler_install returns 1 and wrangler_run uses the shared cache.

WRANGLER_TOOL_RC=87
# Code fallback of settings row lane.fleet-propagate.harness_sync_wrangler_spec.
WRANGLER_SPEC_DEFAULT=wrangler
# Code fallback of settings row lane.fleet-propagate.harness_sync_wrangler_install_retry_s.
WRANGLER_INSTALL_RETRY_S_DEFAULT=3600

wr_root() { printf '%s' "${HARNESS:-${H:-}}"; }
wr_now() { printf '%s' "${HARNESS_SYNC_NOW:-$(date +%s)}"; }

# wr_knob <ENV name> <settings key> — env, then the settings row. Prints the
# raw value or nothing.
wr_knob() {
  local v="${!1:-}" r
  if [ -z "$v" ]; then
    r=$(wr_root)
    [ -n "$r" ] && [ -x "$r/bin/jobs-client.sh" ] \
      && v=$(HARNESS="$r" timeout 10 "$r/bin/jobs-client.sh" setting-get "$2" 2>/dev/null </dev/null | tr -d '[:space:]')
  fi
  printf '%s' "$v"
}

# wrangler_spec — the npx spec for wrangler. Memoised in WRANGLER_SPEC_V, so a
# caller that runs it once before its subshells (harness-sync) reads the
# settings row once per run, not once per D1 round trip. A value that is not
# `wrangler` or `wrangler@<version or range>` falls through to the default.
wrangler_spec() {
  local v
  if [ -z "${WRANGLER_SPEC_V:-}" ]; then
    v=$(wr_knob HARNESS_SYNC_WRANGLER_SPEC lane.fleet-propagate.harness_sync_wrangler_spec)
    [[ "$v" =~ ^wrangler(@[A-Za-z0-9.^~*-]+)?$ ]] || v="$WRANGLER_SPEC_DEFAULT"
    WRANGLER_SPEC_V="$v"
  fi
  printf '%s\n' "$WRANGLER_SPEC_V"
}

wr_install_retry_s() {
  local v
  v=$(wr_knob HARNESS_SYNC_WRANGLER_INSTALL_RETRY_S lane.fleet-propagate.harness_sync_wrangler_install_retry_s)
  case "$v" in ''|*[!0-9]*) v="$WRANGLER_INSTALL_RETRY_S_DEFAULT" ;; esac
  printf '%s\n' "$v"
}

# wrangler_tool_code <outfile> — see the header.
wrangler_tool_code() {
  [ -f "${1:-}" ] || return 0
  if grep -qE '⛅️ wrangler|^[[:space:]]*wrangler [0-9]' "$1" 2>/dev/null; then return 0; fi
  sed -nE 's/^npm (error|ERR!) code (E[A-Z0-9]+)[[:space:]]*$/\2/p' "$1" 2>/dev/null | head -1
}

wr_err_file() {
  local r
  if [ -n "${WRANGLER_TOOL_ERR_FILE:-}" ]; then printf '%s' "$WRANGLER_TOOL_ERR_FILE"; return 0; fi
  r=$(wr_root); [ -n "$r" ] || return 1
  printf '%s/state/wrangler-tool-error' "$r"
}

# wrangler_tool_code_last — the npm code the last rc 87 recorded, or `unknown`.
wrangler_tool_code_last() {
  local f c=""
  f=$(wr_err_file) && c=$(head -1 "$f" 2>/dev/null | tr -cd 'A-Z0-9')
  printf '%s\n' "${c:-unknown}"
}

# wr_cache_dir <outfile> <cache> — the npx directory to move aside: the
# `…/_npx/<hash>` the npm output names, when it exists as a directory under
# <cache>/_npx; else <cache>/_npx.
wr_cache_dir() {
  local p
  p=$(grep -oE '[^[:space:]'\''"]*/_npx/[A-Za-z0-9]+' "$1" 2>/dev/null | head -1)
  if [ -n "$p" ] && [ -d "$p" ] && [ "${p%/_npx/*}/_npx" = "$2/_npx" ]; then printf '%s\n' "$p"; return 0; fi
  printf '%s\n' "$2/_npx"
}

# wr_move_aside <dir> — rename <dir> to <dir>.aside-<epoch>. Earlier aside
# copies of the same parent are removed first, so one copy is kept for
# diagnosis. A rename, never a delete of the live directory.
wr_move_aside() {
  local d="$1" old
  [ -d "$d" ] || return 1
  for old in "${d%/*}"/*.aside-*; do
    case "$old" in */_npx.aside-[0-9]*|*/_npx/*.aside-[0-9]*) rm -rf -- "$old" ;; esac
  done
  mv -T -- "$d" "$d.aside-$(date +%s)"
}

# wr_pinned — print "<cache dir> <version>" of the pinned install when its
# .spec equals the knob; nothing otherwise.
wr_pinned() {
  local r cur dir ver
  r=$(wr_root); [ -n "$r" ] || return 0
  cur="$r/state/wrangler-npx/current"
  [ -L "$cur" ] || return 0
  dir=$(readlink -f "$cur" 2>/dev/null) && [ -d "$dir" ] || return 0
  [ "$(cat "$dir/.spec" 2>/dev/null)" = "$(wrangler_spec)" ] || return 0
  ver=$(cat "$dir/.version" 2>/dev/null)
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || return 0
  printf '%s %s\n' "$dir" "$ver"
}

# wrangler_run [--spec <npx-spec>] <timeout_s> <wrangler args...> — see the header.
wrangler_run() {
  local spec="" cache pin out rc code dir ef attempt first_code="" moved=""
  if [ "${1:-}" = --spec ]; then spec="$2"; shift 2; fi
  local t="$1"; shift
  cache="${npm_config_cache:-$HOME/.npm}"
  if [ -z "$spec" ]; then
    pin=$(wr_pinned)
    if [ -n "$pin" ]; then cache="${pin% *}"; spec="wrangler@${pin##* }"; else spec=$(wrangler_spec); fi
  fi
  out=$(mktemp "${TMPDIR:-/tmp}/wrangler-run.XXXXXX") || return 1
  for attempt in 1 2; do
    npm_config_cache="$cache" timeout "$t" npx --yes "$spec" "$@" >"$out" 2>&1
    rc=$?
    cat "$out"
    code=""
    [ "$rc" != 0 ] && code=$(wrangler_tool_code "$out")
    if [ -z "$code" ]; then
      [ "$attempt" = 2 ] && [ "$rc" = 0 ] \
        && echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') wrangler-run: npx cache healed ($first_code), ${moved:-nothing was moved, the retry passed}"
      rm -f "$out"; return "$rc"
    fi
    [ "$attempt" = 2 ] && break
    first_code="$code"
    dir=$(wr_cache_dir "$out" "$cache")
    if wr_move_aside "$dir" 2>/dev/null; then
      moved="moved $dir aside"
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') wrangler-run: npm error code $code before wrangler started — moved $dir aside, retrying once"
    else
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') wrangler-run: npm error code $code before wrangler started — $dir is not there to move, retrying once"
    fi
  done
  rm -f "$out"
  if ef=$(wr_err_file); then
    mkdir -p "${ef%/*}" 2>/dev/null
    printf '%s\n' "$code" > "$ef.tmp.$$" 2>/dev/null && mv -f "$ef.tmp.$$" "$ef" 2>/dev/null
  fi
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') wrangler-run: wrangler could not start: npm error code $code after one cache move and one retry"
  return "$WRANGLER_TOOL_RC"
}

# wr_pkg_version <cache> — the version of the first wrangler npx installed
# under <cache>/_npx, when it is a valid version.
wr_pkg_version() {
  local f v
  for f in "$1"/_npx/*/node_modules/wrangler/package.json; do
    [ -f "$f" ] || continue
    v=$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$f" | head -1)
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] && { printf '%s\n' "$v"; return 0; }
  done
  return 1
}

# wr_has_version <cache> <ver> — some _npx dir of <cache> holds wrangler <ver>.
wr_has_version() {
  local f
  for f in "$1"/_npx/*/node_modules/wrangler/package.json; do
    [ -f "$f" ] && grep -qE "^[[:space:]]*\"version\"[[:space:]]*:[[:space:]]*\"${2//./\\.}\"" "$f" && return 0
  done
  return 1
}

# wrangler_install — see the header. 0 = current is the knob spec (or the
# lock is busy, or a failed install is inside its retry window); 1 = this
# install failed and `current` is untouched.
wrangler_install() {
  local r
  r=$(wr_root); [ -n "$r" ] || return 1
  mkdir -p "$r/state/wrangler-npx" "$r/locks" 2>/dev/null || return 1
  (
    W="$r/state/wrangler-npx"
    exec {lfd}>"$r/locks/wrangler-install.lock" || exit 1
    flock -n "$lfd" || { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') wrangler-install: another install holds locks/wrangler-install.lock — skipped"; exit 0; }
    for s in "$W"/.stage.*; do
      case "$s" in "$W/.stage."[0-9]*) rm -rf -- "$s" ;; esac
    done
    spec=$(wrangler_spec)
    if [ -L "$W/current" ] && [ "$(cat "$W/current/.spec" 2>/dev/null)" = "$spec" ] \
       && [ -n "$(cat "$W/current/.version" 2>/dev/null)" ]; then
      exit 0
    fi
    now=$(wr_now)
    if read -r fe fspec < "$W/.install-failed" 2>/dev/null && [[ "$fe" =~ ^[0-9]+$ ]] \
       && [ "$fspec" = "$spec" ] && [ "$fe" -le "$now" ] && [ $((now - fe)) -lt "$(wr_install_retry_s)" ]; then
      exit 0
    fi
    fail() {
      rm -rf -- "$stage"
      printf '%s %s\n' "$now" "$spec" > "$W/.install-failed"
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') wrangler-install: $spec not installed ($1) — current is unchanged; wrangler_run uses the shared npx cache; next try in $(wr_install_retry_s)s"
      exit 1
    }
    stage="$W/.stage.$$"
    mkdir -p "$stage" || exit 1
    ( cd "$stage" && npm_config_cache="$stage" npx --yes "$spec" --version </dev/null ) >/dev/null 2>&1 \
      || fail "npx $spec --version failed"
    ver=$(wr_pkg_version "$stage") || fail "no wrangler package.json in the stage cache"
    ( cd "$stage" && npm_config_cache="$stage" npx --yes "wrangler@$ver" --version </dev/null ) >/dev/null 2>&1 \
      || fail "npx wrangler@$ver --version failed"
    wr_has_version "$stage" "$ver" || fail "wrangler@$ver is not in the stage cache"
    printf '%s\n' "$spec" > "$stage/.spec" && printf '%s\n' "$ver" > "$stage/.version" || fail "could not write .spec/.version"
    vdir="v$ver-$now"
    mv -T -- "$stage" "$W/$vdir" || fail "could not rename the stage"
    prev=$(readlink "$W/current" 2>/dev/null)
    ln -sfn "$vdir" "$W/.current.tmp.$$" && mv -T -- "$W/.current.tmp.$$" "$W/current" \
      || { rm -rf -- "${W:?}/$vdir" "$W/.current.tmp.$$"; stage=/nonexistent; fail "could not swap current"; }
    rm -f "$W/.install-failed"
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') wrangler-install: current is wrangler@$ver (spec $spec)"
    # Retention: current and the previous version dir stay; older ones go.
    for d in "$W"/v*; do
      [ -d "$d" ] || continue
      case "${d##*/}" in "$vdir"|"${prev:-/}") ;; v[0-9]*) rm -rf -- "$d" ;; esac
    done
    exit 0
  )
}
