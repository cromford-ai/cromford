#!/bin/bash
# bin/lib/brand-ui-law.sh — the brand law a model stage carries when the repo
# declares a brand/UI rules file (BH-9100). Sourced by bin/agent-call.sh; no
# side effects here.
#
# The law text is prompts/iron-laws.d/20261105-brand-ui.md:
#   line 1   brand-stages: <stage> <stage> ...
#   line 2   empty
#   line 3-  the law text; every {{BRAND_UI_FILE}} becomes the file's path
# Line 1 is NOT a `stages:` line on purpose: sil_text (stage-iron-laws.sh)
# skips the file, because this law depends on the project, the repo and, for a
# review, the diff, and sil_text text is static per stage.

BUL_LAW_FILE=20261105-brand-ui.md
# Code fallback of the settings row `ui.brand_file` (per project:
# `ui.brand_file.<project>`).
BUL_PATH_DEFAULT=docs/claude/brand-ui.md

# _bul_path_ok <v> — rc 0 when <v> is a repo-relative path: charset
# [A-Za-z0-9._/-], 1-200 chars, no leading /, no `..` segment.
_bul_path_ok() {
  local v="$1"
  [[ "$v" =~ ^[A-Za-z0-9._/-]{1,200}$ ]] || return 1
  case "$v" in /*) return 1 ;; esac
  case "/$v/" in */../*) return 1 ;; esac
  return 0
}

# bul_path <project> — the brand file path: env BRAND_UI_FILE, then the row
# `ui.brand_file.<project>`, then the row `ui.brand_file`, then the default.
# rc 2 from setting_get (no row) falls through; rc 1 (an outage, a refused
# key) uses the default. An invalid value prints one stderr line and uses the
# default. Always rc 0.
bul_path() {
  local p="${1:-}" k v rc
  v="${BRAND_UI_FILE:-}"
  v=$(printf '%s' "$v" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  if [ -n "$v" ]; then
    _bul_path_ok "$v" && { printf '%s' "$v"; return 0; }
    echo "brand-ui: BRAND_UI_FILE reads '$v', not a repo-relative path; default $BUL_PATH_DEFAULT" >&2
    printf '%s' "$BUL_PATH_DEFAULT"; return 0
  fi
  if command -v setting_get >/dev/null 2>&1; then
    for k in ${p:+"ui.brand_file.$p"} ui.brand_file; do
      rc=0; v=$(setting_get "$k" 2>/dev/null 7>&- 8>&-) || rc=$?
      case "$rc" in
        0) v=$(printf '%s' "$v" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
           _bul_path_ok "$v" && { printf '%s' "$v"; return 0; }
           echo "brand-ui: $k reads '$v', not a repo-relative path; default $BUL_PATH_DEFAULT" >&2
           break ;;
        2) continue ;;
        *) break ;;
      esac
    done
  fi
  printf '%s' "$BUL_PATH_DEFAULT"
}

# bul_repo_dir <project> — env AGENT_CALL_REPO_DIR, then
# ${REPOS_ROOT:-/root/repos}/<project>, then the git top level of $PWD. Prints
# nothing when none is a directory. Always rc 0.
bul_repo_dir() {
  local p="${1:-}" d
  d="${AGENT_CALL_REPO_DIR:-}"
  [ -n "$d" ] && [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  d="${REPOS_ROOT:-/root/repos}/$p"
  [ -n "$p" ] && [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  d=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || d=""
  printf '%s' "$d"
  return 0
}

# bul_globs — the globs that make a review diff a UI change: env
# BRAND_UI_GLOBS, then the row `ui.brand_ui_globs`, then the code fallback
# below (the e2e UI globs plus component and style extensions).
bul_globs() {
  local v rc
  v="${BRAND_UI_GLOBS:-}"
  case "$v" in *[![:space:]]*) printf '%s' "$v"; return 0 ;; esac
  if command -v setting_get >/dev/null 2>&1; then
    rc=0; v=$(setting_get ui.brand_ui_globs 2>/dev/null 7>&- 8>&-) || rc=$?
    [ "$rc" = 0 ] && case "$v" in *[![:space:]]*) printf '%s' "$v"; return 0 ;; esac
  fi
  printf '%s' "$E2E_UI_GLOBS_DEFAULT *.tsx *.jsx *.vue *.svelte *.scss *.sass *.less"
}

# bul_ui_hit <prompt-text> — rc 0 when the change touches UI, rc 1 when it
# touches only non-UI files, rc 2 when the file list is unknown. The list is
# every `diff --git a/X` path in the prompt; with none, the
# `git diff --name-only ${AGENT_CALL_DIFF_BASE:-origin/main}...HEAD` of $PWD.
bul_ui_hit() {
  local files lib
  files=$(grep -oE '^diff --git a/[^ ]+' <<<"${1:-}" 2>/dev/null | sed 's|^diff --git a/||')
  if [ -z "$files" ] && git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    files=$(git -C "$PWD" diff --name-only "${AGENT_CALL_DIFF_BASE:-origin/main}...HEAD" 2>/dev/null) || files=""
  fi
  [ -n "$files" ] || return 2
  lib="$(dirname "${BASH_SOURCE[0]}")/e2e-ui-paths.sh"
  # shellcheck source=/dev/null
  { [ -r "$lib" ] && . "$lib"; } || return 2
  E2E_PATHS="$(bul_globs)" e2e_ui_path_hit <<<"$files"
}

# bul_text <stage> <project> <prompt-text> <out-file> <laws-dir> — print the
# brand law for <stage>, with the path filled in, or print nothing. Nothing
# when the stage is not on the brand-stages line, when the repo has no brand
# file (and then the note below is written once), or when a review stage's diff
# touches no UI file. An unknown file list keeps the law. Always rc 0.
# The note: <out-file's dir>/brand-ui-note.txt, one line, written when absent.
bul_text() {
  local stage="${1:-}" p="${2:-}" prompt="${3:-}" out="${4:-}" dir="${5:-}" f first w hit=0 path repo note body
  local -a words
  f="$dir/$BUL_LAW_FILE"
  [ -n "$stage" ] && [ -f "$f" ] && [ -r "$f" ] || return 0
  first=""; IFS= read -r first < "$f" || [ -n "$first" ] || return 0
  first="${first//$'\r'/}"
  case "$first" in brand-stages:*) ;; *) return 0 ;; esac
  read -ra words <<< "${first#brand-stages:}"
  for w in ${words[@]+"${words[@]}"}; do [ "$w" = "$stage" ] && { hit=1; break; }; done
  [ "$hit" = 1 ] || return 0
  path=$(bul_path "$p")
  repo=$(bul_repo_dir "$p")
  if [ -z "$repo" ] || [ ! -f "$repo/$path" ] || [ ! -r "$repo/$path" ]; then
    if [ -n "$out" ]; then
      note="$(dirname "$out")/brand-ui-note.txt"
      [ -e "$note" ] || printf 'brand-ui: %s: no brand file at %s in %s; brand rule not applied (BH-9100)\n' \
        "$p" "$path" "${repo:-no repo dir}" 2>/dev/null > "$note" || true
    fi
    return 0
  fi
  case "$stage" in
    review|lead-review) bul_ui_hit "$prompt"; [ "$?" = 1 ] && return 0 ;;
  esac
  body=$(tail -n +3 "$f" | tr -d '\r'; printf x); body="${body%x}"
  body="${body%$'\n'}"
  printf '%s\n' "${body//\{\{BRAND_UI_FILE\}\}/$path}"
  return 0
}
