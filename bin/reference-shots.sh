#!/bin/bash
# bin/reference-shots.sh — BH-6485: host preview QA's reference shots and write
# the PR body's "## Reference screenshots" section.
#
#   reference-shots.sh publish <build> <repo> <owner/repo> <key> <base-sha>
#   reference-shots.sh prune <repo>
#
# PUBLISH. The ticket body (<build>/ticket-meta.json, else ticket-body.md) names
# `Reference: <path>` lines (bin/lib/spec-trace.sh). No such line: nothing is
# written. Otherwise, after prune, it checks that every Reference x {light,
# dark} x {1440, 390} shot exists as <build>/qa-shots/ref/<slug>-<theme>-<w>.png
# and that each reference file exists at <base-sha>. A complete set becomes ONE
# orphan commit (a temp GIT_INDEX_FILE, hash-object, write-tree, commit-tree:
# the PR branch and its head are never touched), force-pushed to
# refs/heads/harness-shots/<key-lower>-<yyyymmdd> on origin. Only when
# `git ls-remote` shows that ref at the pushed sha is <build>/reference-shots.md
# written with images: a table row per shot, the preview image next to the
# reference image. An incomplete set writes the heading and `Missing: <list>`;
# a failed push writes `Could not publish: <why>`. Neither has image markup, so
# the self-check row body-reference-shots refuses the body. It always exits 0:
# a shot that could not be hosted never ends a build.
#
# PRUNE (retention, the iron law). One `git ls-remote` lists harness-shots/*.
# A name whose date is older than REFERENCE_SHOTS_KEEP_DAYS is a candidate.
# REFERENCE_SHOTS_PRUNE: dry (default) logs them only, on deletes up to
# REFERENCE_SHOTS_PRUNE_MAX, off does nothing. Never a ref outside
# refs/heads/harness-shots/. One audit line per run.
#
# Logs: one line per run in $HARNESS/logs/reference-shots.log, and one line in
# <build>/pipeline.log for a publish. REFERENCE_SHOTS_NOW (epoch seconds) is the
# clock seam. The knobs come from catalog/lanes.d/_lib.spec-trace.json.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS="${HARNESS:-/root/harness}"
# shellcheck source=bin/lib/spec-trace.sh
. "$SELF_DIR/lib/spec-trace.sh" || { echo "reference-shots.sh: bin/lib/spec-trace.sh is missing" >&2; exit 0; }

NOW="${REFERENCE_SHOTS_NOW:-$(date -u +%s)}"
case "$NOW" in ''|*[!0-9]*) NOW=$(date -u +%s) ;; esac
STAMP() { date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ; }
audit() { mkdir -p "$HARNESS/logs" 2>/dev/null; printf '%s %s\n' "$(STAMP)" "$1" >> "$HARNESS/logs/reference-shots.log" 2>/dev/null; return 0; }

prune() { # prune <repo>
  local repo="$1" list name d cutoff cand=() n=0 del=0 fail=0 names=""
  st_conf "${PROJECT:-}"
  [ -n "$ST_CONF_WARN" ] && audit "prune knob warning: $ST_CONF_WARN"
  if [ "$ST_PRUNE" = off ]; then audit "prune mode=off keep_days=$ST_KEEP_DAYS candidates=- deleted=0"; return 0; fi
  if ! list=$(git -C "$repo" ls-remote origin 'refs/heads/harness-shots/*' 2>/dev/null); then
    audit "prune mode=$ST_PRUNE keep_days=$ST_KEEP_DAYS could not list origin"; return 0
  fi
  cutoff=$(date -u -d "@$((NOW - ST_KEEP_DAYS * 86400))" +%Y%m%d)
  while read -r _ name; do
    case "$name" in refs/heads/harness-shots/*) ;; *) continue ;; esac
    d=$(sed -nE 's#^refs/heads/harness-shots/.*-([0-9]{8})$#\1#p' <<<"$name")
    [ -n "$d" ] && [ "$d" -lt "$cutoff" ] && cand+=("$name")
  done <<<"$list"
  [ "${#cand[@]}" -gt 0 ] && names=$(printf '%s\n' "${cand[@]#refs/heads/}" | paste -sd, -)
  if [ "$ST_PRUNE" = on ]; then
    for name in ${cand[@]+"${cand[@]}"}; do
      [ "$n" -lt "$ST_PRUNE_MAX" ] || break
      n=$((n + 1))
      if git -C "$repo" push -q origin --delete "$name" >/dev/null 2>&1; then
        del=$((del + 1)); audit "prune deleted ${name#refs/heads/}"
      else
        fail=$((fail + 1)); audit "prune could not delete ${name#refs/heads/}"
      fi
    done
  fi
  audit "prune mode=$ST_PRUNE keep_days=$ST_KEEP_DAYS cutoff=$cutoff candidates=${#cand[@]} deleted=$del failed=$fail max=$ST_PRUNE_MAX names=${names:--}"
  return 0
}

publish() { # publish <build> <repo> <slug> <key> <base-sha>
  local build="$1" repo="$2" slug="$3" key="$4" base="$5" tk refs r th w f out miss=() shots=()
  local keyl day ref idx tree commit="" got why="" md s b
  tk="$build/ticket-meta.json"; [ -r "$tk" ] || tk="$build/ticket-body.md"
  refs=$(st_parse reference "$tk" 2>/dev/null)
  [ -n "$refs" ] || return 0
  prune "$repo"
  md="$build/reference-shots.md"
  keyl=$(printf '%s' "$key" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9.-]/-/g')
  day=$(date -u -d "@$NOW" +%Y%m%d)
  ref="harness-shots/${keyl}-${day}"
  # A name two references share would host one image for both.
  out=$(st_shot_names "$tk" | awk -F'\t' '{print $4}' | sort | uniq -d | head -3 | paste -sd, -)
  [ -n "$out" ] && miss+=("two references share the shot name ($out)")
  [[ "$base" =~ ^[0-9a-f]{7,40}$ ]] || miss+=("no base sha to read the references at")
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if ! [[ "$r" =~ ^[A-Za-z0-9._/-]+$ ]]; then miss+=("$r: unsupported path"); continue; fi
    if [ -n "$base" ] && ! git -C "$repo" cat-file -e "${base}:${r}" 2>/dev/null; then
      miss+=("$r: reference not found at ${base:0:8}")
    fi
  done <<<"$refs"
  while IFS=$'\t' read -r r th w f; do
    [ -n "$f" ] || continue
    if [ -s "$build/qa-shots/ref/$f" ]; then shots+=("$r"$'\t'"$th"$'\t'"$w"$'\t'"$f")
    else miss+=("qa-shots/ref/$f"); fi
  done < <(st_shot_names "$tk")
  if [ "${#miss[@]}" = 0 ]; then
    idx=$(mktemp "${TMPDIR:-/tmp}/refshots-idx.XXXXXX") && rm -f "$idx"
    tree=$(
      for s in "${shots[@]}"; do
        IFS=$'\t' read -r _ _ _ f <<<"$s"
        b=$(git -C "$repo" hash-object -w "$build/qa-shots/ref/$f") || exit 1
        GIT_INDEX_FILE="$idx" git -C "$repo" update-index --add --cacheinfo "100644,$b,$f" || exit 1
      done
      GIT_INDEX_FILE="$idx" git -C "$repo" write-tree
    ) || tree=""
    rm -f "$idx"
    if [ -z "$tree" ]; then why="the shots could not be written to a tree"
    elif ! commit=$(GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-cromford}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-harness@users.noreply.github.com}" \
                    GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-cromford}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-harness@users.noreply.github.com}" \
                    git -C "$repo" commit-tree "$tree" -m "harness-shots: $key reference screenshots" 2>/dev/null) || [ -z "$commit" ]; then
      why="the shots commit could not be made"
    elif ! git -C "$repo" push -q --force origin "$commit:refs/heads/$ref" >/dev/null 2>&1; then
      why="the push of $ref was rejected"
    else
      got=$(git -C "$repo" ls-remote origin "refs/heads/$ref" 2>/dev/null | awk '{print $1}' | head -1)
      [ "$got" = "$commit" ] || why="origin does not show $ref at ${commit:0:8} after the push"
    fi
  fi
  {
    printf '## Reference screenshots\n\n'
    if [ "${#miss[@]}" -gt 0 ]; then
      printf 'The reference set is incomplete, so no image is shown.\n\nMissing: %s\n' "$(printf '%s\n' "${miss[@]}" | paste -sd';' - | sed 's/;/; /g')"
    elif [ -n "$why" ]; then
      printf 'The shots exist, but they are not hosted, so no image is shown.\n\nCould not publish: %s\n' "$why"
    else
      printf 'Preview QA shots next to the reference images the ticket names. The shots are on branch `%s` at `%s`; the PR branch is not changed.\n\n' "$ref" "${commit:0:12}"
      printf '| Reference | Theme | Width | Preview | Reference image |\n|---|---|---|---|---|\n'
      for s in "${shots[@]}"; do
        IFS=$'\t' read -r r th w f <<<"$s"
        printf '| `%s` | %s | %s | ![preview](https://github.com/%s/blob/%s/%s?raw=true) | ![reference](https://github.com/%s/blob/%s/%s?raw=true) |\n' \
          "$r" "$th" "$w" "$slug" "$commit" "$f" "$slug" "$base" "$r"
      done
    fi
  } > "$md"
  if [ "${#miss[@]}" -gt 0 ]; then out="status=missing missing=${#miss[@]}"
  elif [ -n "$why" ]; then out="status=could-not-publish why=\"$why\""
  else out="status=published ref=$ref sha=${commit:0:12} shots=${#shots[@]}"; fi
  audit "publish $key $out"
  printf '%s [%s/%s] REFERENCE SHOTS: %s\n' "$(STAMP)" "${PROJECT:-?}" "$key" "$out" >> "$build/pipeline.log" 2>/dev/null
  return 0
}

case "${1:-}" in
  publish)
    [ $# -ge 6 ] || { echo "usage: reference-shots.sh publish <build> <repo> <owner/repo> <key> <base-sha>" >&2; exit 2; }
    publish "$2" "$3" "$4" "$5" "$6" ;;
  prune)
    [ $# -ge 2 ] || { echo "usage: reference-shots.sh prune <repo>" >&2; exit 2; }
    prune "$2" ;;
  *) sed -n '2,6p' "$0" >&2; exit 2 ;;
esac
exit 0
