#!/bin/bash
# bin/lib/ci-env.sh — the CI locale and Postgres collation a box run must use
# (BH-9285). Sourced, never executed. Functions only.
#
# WHY. A box run used the box locale (`C` on a pool machine) and an initdb with
# no --locale, so a sort or an ORDER BY came out in byte order. project-6 CI
# sorts with glibc `en_US` (its Postgres image default), and PR #3661 went red
# in CI on exactly that difference after the box said green.
#
# CONTRACT
#   ce_resolve <repo> [workflow-file]
#                         sets CE_LOCALE, CE_SOURCE (knob|workflow|fallback)
#                         and CE_COLLATION in the caller's shell. Order:
#                           1. the knob CI_LOCALE (row lib.ci-env[.<project>].ci_locale,
#                              then the env), when it is a valid name;
#                           2. a TOP-LEVEL `env:` LC_ALL, else LANG, in
#                              <repo>/.github/workflows/ci.yml, else
#                              harness-ci.yml, or in [workflow-file] when given
#                              (job-level env is not read);
#                           3. CE_FALLBACK_LOCALE (en_US.UTF-8).
#                         A value must match ^[A-Za-z0-9_.@-]{1,64}$. The workflow
#                         is PR-controlled input, so a bad value is ignored and
#                         the next source answers.
#                         CE_COLLATION is the knob CI_PG_COLLATION when it is a
#                         valid name, else CE_LOCALE.
#   ce_locale_installed <loc>
#                         rc 0 when `locale -a` lists it (en_US.UTF-8 and
#                         en_US.utf8 are the same name). C and POSIX always are.
#   ce_suite_record <repo> <outfile>
#                         resolves, sets CE_ENV=(LANG=<loc> LC_ALL=<loc>) and
#                         appends one HARNESS_LOCALE: line to <outfile>. rc 2
#                         (CE_ENV empty) when the locale or the collation is not
#                         installed: a run never falls back to the box locale in
#                         silence.
#
# Knobs: CI_LOCALE, CI_PG_COLLATION (catalog/lanes.d/_lib.ci-env.json). Both are
# empty by default; empty means "the next source in the order above".

# The documented fallback when the row lib.ci-env.ci_locale is empty and the
# workflow declares no locale: project-6 CI's Postgres image default.
CE_FALLBACK_LOCALE=en_US.UTF-8
_CE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _ce_knob <ENV> — lane_knob in libs scope (with $PROJECT) when the caller has
# it, else the harness root's lane-gate.sh in a subshell, else the env.
_ce_knob() {
  local _LG_KIND=libs v="" root="${HARNESS:-${H:-}}" lg
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob ci-env "$1" "${PROJECT:-}" 2>/dev/null)
  else
    for lg in ${root:+"$root/bin/lib/lane-gate.sh"} "$_CE_LIB/lane-gate.sh"; do
      [ -r "$lg" ] || continue
      v=$( . "$lg" 2>/dev/null && _LG_KIND=libs lane_knob ci-env "$1" "${PROJECT:-}" 2>/dev/null )
      break
    done
  fi
  [ -n "$v" ] || v="${!1:-}"
  printf '%s' "$v"
}

# _ce_valid <value> — rc 0 for a locale-shaped name, nothing else.
_ce_valid() { [[ "${1:-}" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]]; }

# _ce_workflow_locale <repo> [workflow-file] — the top-level env LC_ALL (else
# LANG) of the given workflow, else the repo's main CI workflow. Empty when
# there is none or it cannot be parsed.
_ce_workflow_locale() {
  local repo="${1:-.}" wf="${2:-}"
  if [ -z "$wf" ]; then
    for wf in "$repo/.github/workflows/ci.yml" "$repo/.github/workflows/harness-ci.yml"; do
      [ -f "$wf" ] && break
      wf=""
    done
  fi
  [ -f "$wf" ] || wf=""
  [ -n "$wf" ] || return 0
  python3 -I -c '
import sys
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
e = d.get("env") if isinstance(d, dict) else None
if isinstance(e, dict):
    for k in ("LC_ALL", "LANG"):
        v = e.get(k)
        if isinstance(v, str) and v:
            print(v); break
' "$wf" 2>/dev/null | head -1
}

ce_resolve() {
  local repo="${1:-.}" wfile="${2:-}" v
  CE_LOCALE=""; CE_SOURCE=""; CE_COLLATION=""
  v=$(_ce_knob CI_LOCALE)
  if _ce_valid "$v"; then CE_LOCALE="$v"; CE_SOURCE=knob
  else
    v=$(_ce_workflow_locale "$repo" "$wfile")
    if _ce_valid "$v"; then CE_LOCALE="$v"; CE_SOURCE=workflow
    else CE_LOCALE="$CE_FALLBACK_LOCALE"; CE_SOURCE=fallback
    fi
  fi
  v=$(_ce_knob CI_PG_COLLATION)
  if _ce_valid "$v"; then CE_COLLATION="$v"; else CE_COLLATION="$CE_LOCALE"; fi
  return 0
}

# _ce_norm <loc> — the name `locale -a` prints: the codeset lowercased with no dash.
_ce_norm() {
  local l="${1:-}" base cs
  case "$l" in *.*) base="${l%%.*}"; cs="${l#*.}" ;; *) printf '%s' "$l"; return ;; esac
  cs=$(printf '%s' "$cs" | tr 'A-Z' 'a-z' | tr -d '-')
  printf '%s.%s' "$base" "$cs"
}

ce_locale_installed() {
  local want l
  case "${1:-}" in C|POSIX) return 0 ;; '') return 1 ;; esac
  want=$(_ce_norm "$1")
  while IFS= read -r l; do
    [ "$(_ce_norm "$l")" = "$want" ] && return 0
  done < <(locale -a 2>/dev/null)
  return 1
}

# ce_suite_record <repo> <outfile> — HARNESS_SUITE_RUN's one call. Resolves the
# locale, sets CE_ENV to (LANG=<loc> LC_ALL=<loc>) and appends
#   HARNESS_LOCALE: <loc> (source: <knob|workflow|fallback>, collation <c>)   rc 0
#   HARNESS_LOCALE: could-not-run (locale <x> not installed; source: <s>)   rc 2, CE_ENV empty
ce_suite_record() {
  local repo="${1:-.}" out="${2:-/dev/null}" n
  CE_ENV=()
  ce_resolve "$repo"
  for n in "$CE_LOCALE" "$CE_COLLATION"; do
    if ! ce_locale_installed "$n"; then
      echo "HARNESS_LOCALE: could-not-run (locale $n not installed; source: $CE_SOURCE)" >> "$out"
      return 2
    fi
  done
  CE_ENV=("LANG=$CE_LOCALE" "LC_ALL=$CE_LOCALE")
  echo "HARNESS_LOCALE: $CE_LOCALE (source: $CE_SOURCE, collation $CE_COLLATION)" >> "$out"
  return 0
}
