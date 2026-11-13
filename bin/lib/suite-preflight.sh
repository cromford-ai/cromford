# bin/lib/suite-preflight.sh — BH-7695: check that this box CAN run a repo's
# suite before a review reads the suite's exit as evidence about the code.
#
# THE INCIDENT. On 2026-10-20 a build box ran project-6 #2084's suite with no
# node_modules and no DATABASE_URL. The suite exit was 127, the lens prompt
# reads a nonzero exit as a BLOCK, and the PR was blocked for the box. The same
# suites passed on a set-up machine (unit 276/276, e2e 3/3).
#
# Two callers, each loads this file lazily; no file means today's behavior:
#   HARNESS_SUITE_RUN's npm arm (bin/lib/rb/gates.sh): sp_build_pre before the
#     prelude (one setup attempt, one re-check), sp_build_post before the exit.
#   the lead review host suite (bin/lead-review.sh, via libs.d): sp_lead_suite,
#     which uses sp_hard and sp_soft only. No install, no fail, no alert: a fresh
#     lead worktree never has node_modules, and the review must still finish
#     with a verdict.
#
# THE ITEMS.
#   node_modules  HARD. The repo declares npm dependencies, the command is a
#                 node command (or empty: the npm arm) that does not install its
#                 own packages, and node_modules is absent or empty with no Yarn
#                 PnP file. The suite cannot run, so it is not run.
#   DATABASE_URL  SOFT. A prisma repo with no URL anywhere (env, .env*, the
#                 throwaway Postgres) whose RED suite output carries a database
#                 connection signature. A green stays green; an assertion red
#                 stays red.
#   <NAME>        SOFT. Each name in the fly-pool knob SUITE_PREFLIGHT_ENV
#                 (per project) whose value is empty, on a red suite.
# A package.json that jq cannot read makes no claim (fail open to today).
#
# THE RECORD. `HARNESS_EXIT: could-not-run: <items>[ (suite rc <n>)]` and one
# `HARNESS_PREFLIGHT:` line (sp_note). LIVE_SUITE reads it as not-run.
#
# Sourced, never run. Safe under `set -u`. No network except in sp_install.
# shellcheck shell=bash

# A contract command that installs its own packages is never a node_modules miss.
SP_INSTALL_RE='(^|[;&|[:space:]])(npm (ci|install|i)|pnpm (i|install)|yarn install|bun (i|install))([;&|[:space:]]|$)|(^|[;&|[:space:]])yarn[[:space:]]*([;&|]|$)'
# A suite output line that says the database, not the code, failed.
SP_DB_RE="P1001|P1012|Environment variable not found: DATABASE_URL|Can't reach database server|PrismaClientInitializationError"

# sp_hard <dir> <cmd-or-empty> — sets SP_HARD (`node_modules` or empty).
#   rc 0 when SP_HARD is empty (the box can run the suite), else 1.
sp_hard() {
  local d="${1:-.}" cmd="${2:-}" n w
  SP_HARD=""
  [ -r "$d/package.json" ] && command -v jq >/dev/null 2>&1 || return 0
  n=$(jq -r '((.dependencies // {}) + (.devDependencies // {})) | length' "$d/package.json" 2>/dev/null) || return 0
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] || return 0
  read -r w _ <<<"$cmd"
  case "${w:-}" in ''|npm|npx|node|yarn|pnpm|bun|vitest|jest|playwright|tsx) ;; *) return 0 ;; esac
  [ -n "$cmd" ] && [[ "$cmd" =~ $SP_INSTALL_RE ]] && return 0
  [ -e "$d/.pnp.cjs" ] && return 0
  [ -d "$d/node_modules" ] && [ -n "$(ls -A "$d/node_modules" 2>/dev/null)" ] && return 0
  SP_HARD=node_modules
  return 1
}

# sp_soft <dir> <db-provided 0|1> <project> <suite-output> <from-line> — sets
#   SP_SOFT (item names joined by ", "). rc 0 when SP_SOFT is non-empty (a miss),
#   else 1. Only the output from <from-line> on is read for the DB signature, so
#   the prelude's own lines above it never count.
sp_soft() {
  local d="${1:-.}" db="${2:-0}" p="${3:-}" out="${4:-/dev/null}" from="${5:-1}" f n names
  local soft=()
  SP_SOFT=""
  [[ "$from" =~ ^[0-9]+$ ]] || from=1
  if { [ -f "$d/prisma/schema.prisma" ] || [ -d "$d/prisma/schema" ]; } && [ "$db" != 1 ] && [ -z "${DATABASE_URL:-}" ]; then
    n=0
    for f in .env .env.test .env.local; do
      grep -qE '^DATABASE_URL=.+' "$d/$f" 2>/dev/null && { n=1; break; }
    done
    if [ "$n" = 0 ] && grep -qE "$SP_DB_RE" <<<"$(tail -n "+$from" "$out" 2>/dev/null)"; then
      soft+=(DATABASE_URL)
    fi
  fi
  names=$(sp_knob SUITE_PREFLIGHT_ENV "$p")
  for n in $names; do
    if [[ ! "$n" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
      echo "suite-preflight: SUITE_PREFLIGHT_ENV name '$n' is not an env name; ignored" >&2
      continue
    fi
    [ -n "${!n:-}" ] && continue
    [[ " ${soft[*]} " == *" $n "* ]] || soft+=("$n")
  done
  [ "${#soft[@]}" -gt 0 ] || return 1
  SP_SOFT=$(printf '%s, ' "${soft[@]}"); SP_SOFT="${SP_SOFT%, }"
  return 0
}

# sp_knob <ENV> <project> — the fly-pool knob: settings row, then env, then the
#   fallback. Resolved in a subshell so lane-gate.sh's globals never land in the
#   caller (pgt_knob's shape, bin/lib/pg-test.sh). A value out of type falls to
#   the fallback.
sp_knob() {
  local e="${1:-}" p="${2:-}" lg v="" self root
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="${HARNESS:-${H:-}}"
  for lg in ${root:+"$root/bin/lib/lane-gate.sh"} "$self/lane-gate.sh"; do
    [ -r "$lg" ] || continue
    v=$( . "$lg" 2>/dev/null && lane_knob fly-pool "$e" "$p" 2>/dev/null )
    break
  done
  [ -n "$v" ] || v="${!e:-}"
  case "$e" in
    # fallback 1: settings row fly-pool/SUITE_PREFLIGHT_INSTALL
    SUITE_PREFLIGHT_INSTALL) case "$v" in 0|1) ;; *) v=1 ;; esac ;;
    # fallback 900: settings row fly-pool/SUITE_PREFLIGHT_SETUP_S
    SUITE_PREFLIGHT_SETUP_S) { [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 60 ] && [ "$v" -le 3600 ]; } || v=900 ;;
    # fallback "": settings row fly-pool/SUITE_PREFLIGHT_ENV
    SUITE_PREFLIGHT_ENV) ;;
  esac
  printf '%s' "$v"
}

# sp_install <dir> <log-file> — the ONE setup attempt: `npm ci` with a lockfile,
#   else `npm install --no-package-lock` (no stray lockfile in the worktree),
#   bounded by the SUITE_PREFLIGHT_SETUP_S knob, output appended to
#   <log-file>. Sets SP_SETUP="<cmd> (rc=<n>)" and returns the rc. The rc alone
#   is not trusted: the caller runs sp_hard again.
sp_install() {
  local d="${1:-.}" log="${2:-/dev/null}" rc to
  local cmd=(npm install --no-audit --no-fund --no-package-lock)
  [ -f "$d/package-lock.json" ] && cmd=(npm ci --no-audit --no-fund)
  to=$(sp_knob SUITE_PREFLIGHT_SETUP_S "${PROJECT:-}")
  ( cd "$d" && timeout "$to" "${cmd[@]}" ) >> "$log" 2>&1; rc=$?
  SP_SETUP="${cmd[*]} (rc=$rc)"
  return "$rc"
}

# sp_alert_once <state-dir> <project> <text> — one alert per project per box per
#   UTC day, through bin/alert-line.sh --id. The flag dir is made FIRST (rc 2 and
#   no alert if it cannot be, or if no harness root is set). rc 1: already alerted today. The flag is touched
#   after the alert, so a crash between them costs one duplicate line, never a
#   lost alert. Every other flag of the project is deleted: only today's has a use.
sp_alert_once() {
  local dir="${1:-}/suite-preflight" p today f old host root="${HARNESS:-${H:-}}"
  p=$(printf '%s' "${2:-}" | tr -cd 'A-Za-z0-9._-'); p="${p:-none}"
  [ -n "$root" ] && [ -n "${1:-}" ] || return 2
  mkdir -p "$dir" 2>/dev/null || return 2
  # SUITE_PREFLIGHT_TODAY (YYYYMMDD) is a test seam only.
  today="${SUITE_PREFLIGHT_TODAY:-$(date -u +%Y%m%d)}"; f="$dir/alerted-$p-$today"
  [ -e "$f" ] && return 1
  host=$(hostname 2>/dev/null || echo unknown)
  HARNESS="$root" "$root/bin/alert-line.sh" --id "suite-preflight-$p-$host" "${3:-}" >/dev/null 2>&1 || true
  : > "$f" 2>/dev/null
  for old in "$dir/alerted-$p-"*; do
    [ -e "$old" ] && [ "$old" != "$f" ] && rm -f "$old"
  done
  return 0
}

# sp_note <items> [<suite rc>] — the one HARNESS_PREFLIGHT text both paths use.
sp_note() {
  local items="${1:-}" rc="${2:-}"
  printf 'HARNESS_PREFLIGHT: could-not-run: %s%s — the box lacks %s; this is not a test result: a [NOTE] not verified here, never a BLOCK; the CI run on the PR head is the suite verdict\n' \
    "$items" "${rc:+ (suite rc $rc)}" "$items"
}

# sp_build_pre <outfile> <phase> — HARNESS_SUITE_RUN, npm arm, before the prelude
#   (cwd = the build worktree; $BUILD, $PROJECT, $KEY, $HARNESS set). rc 0: go on.
#   rc 1: node_modules is still missing after the one setup attempt; the record
#   is written, HARNESS_EXIT last, and the caller returns without running.
sp_build_pre() {
  local f="$BUILD/${1:-}" phase="${2:-}"
  sp_hard . "" && return 0
  SP_SETUP="none (SUITE_PREFLIGHT_INSTALL=0)"
  if [ "$(sp_knob SUITE_PREFLIGHT_INSTALL "${PROJECT:-}")" = 1 ]; then
    sp_install . "$f"
    echo "HARNESS_PREFLIGHT: setup $SP_SETUP" >> "$f"
    echo "$(STAMP) [$PROJECT/$KEY] HARNESS-VERIFY $phase preflight: setup $SP_SETUP" >> "$BUILD/pipeline.log"
    sp_hard . "" && return 0
  fi
  sp_note "$SP_HARD" >> "$f"
  command -v RB_TOKEN_REDACT >/dev/null 2>&1 && RB_TOKEN_REDACT "$f"
  echo "HARNESS_EXIT: could-not-run: $SP_HARD" >> "$f"
  echo "$(STAMP) [$PROJECT/$KEY] HARNESS-VERIFY $phase preflight: could-not-run: $SP_HARD" >> "$BUILD/pipeline.log"
  sp_alert_once "${HARNESS:-}/state" "${PROJECT:-}" \
    "[suite-preflight] $PROJECT/$KEY on $(hostname 2>/dev/null || echo unknown): could-not-run: $SP_HARD after one setup attempt ($SP_SETUP). The box cannot install this repo's packages. Infra, not a PR finding."
  return 1
}

# sp_build_post <outfile> <rc> <db-provided 0|1> <from-line> [<phase>] — HARNESS_SUITE_RUN,
#   npm arm, before the HARNESS_EXIT line. Acts only on an integer rc other than
#   0 with a soft miss: writes the note, sets SP_RC="could-not-run: <items>
#   (suite rc <rc>)", logs, alerts once, rc 0. Every other case: rc 1, SP_RC=<rc>.
sp_build_post() {
  local f="$BUILD/${1:-}" rc="${2:-}" db="${3:-0}" from="${4:-1}" phase="${5:-suite}"
  SP_RC="$rc"
  [[ "$rc" =~ ^[0-9]+$ ]] && [ "$rc" != 0 ] || return 1
  sp_soft . "$db" "${PROJECT:-}" "$f" "$from" || return 1
  sp_note "$SP_SOFT" "$rc" >> "$f"
  SP_RC="could-not-run: $SP_SOFT (suite rc $rc)"
  echo "$(STAMP) [$PROJECT/$KEY] HARNESS-VERIFY $phase preflight: $SP_RC" >> "$BUILD/pipeline.log"
  sp_alert_once "${HARNESS:-}/state" "${PROJECT:-}" \
    "[suite-preflight] $PROJECT/$KEY on $(hostname 2>/dev/null || echo unknown): $SP_RC. The box lacks $SP_SOFT for this repo's suite. Infra, not a PR finding."
  return 0
}

# sp_lead_suite <wt> <cmd> <timeout-s> <project> <out> — the lead review host
#   suite with the preflight. Sets SP_LINE (the report's `host suite:` text) and
#   SP_RC (the suite rc; empty when the suite did not run). Always rc 0.
#   HARD miss: the suite does not run; <out> holds the note. Else the suite runs
#   exactly as it did before this lib (`host suite: <cmd> rc=<rc>`); a red rc
#   with a SOFT miss becomes `host suite: could-not-run: <items> (suite rc <rc>):
#   <cmd>`, and the note goes first and last in <out> (the prompt shows only the
#   suite's last 80 lines). No install, no alert, no fail.
sp_lead_suite() {
  local wt="${1:-.}" cmd="${2:-}" to="${3:-0}" p="${4:-}" out="${5:-/dev/null}" rc
  SP_RC=""
  if ! sp_hard "$wt" "$cmd"; then
    SP_LINE="host suite: could-not-run: $SP_HARD (not run; the review worktree has no installed packages): $cmd"
    { sp_note "$SP_HARD"
      printf '%s\n' "No host suite ran on this head. The PR head's CI is the suite verdict. Do not claim local test evidence, and do not BLOCK on this."; } > "$out"
    return 0
  fi
  ( cd "$wt" && timeout "$to" bash -c "$cmd" ) 7>&- 8>&- > "$out" 2>&1; rc=$?
  SP_RC="$rc"
  SP_LINE="host suite: $cmd rc=$rc"
  if [ "$rc" != 0 ] && sp_soft "$wt" 0 "$p" "$out" 1; then
    SP_LINE="host suite: could-not-run: $SP_SOFT (suite rc $rc): $cmd"
    { sp_note "$SP_SOFT" "$rc"; cat "$out"; sp_note "$SP_SOFT" "$rc"; } > "$out.sp" && mv "$out.sp" "$out"
  fi
  return 0
}
