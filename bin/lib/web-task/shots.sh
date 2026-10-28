#!/bin/bash
# bin/lib/web-task/shots.sh — publish a web-task run's screenshots (BH-7594).
#
#   wt_shots_publish <slug> <KEY> <file...>
#
# The job artifacts route (/api/artifacts over job_artifacts) stores metadata
# only, never bytes, so the bytes go to a branch of the ticket's own repo, the
# bin/reference-shots.sh precedent: harness-shots/<key-lower>-web-task holds ONE
# parentless commit with the files (at most WT_SHOTS_MAX; more are counted and ignored).
# The steps, all through gh_rest (the git data REST API, no checkout):
#   1. POST git/blobs per file (base64, the body goes by --input FILE)
#   2. POST git/trees (no base tree), POST git/commits (no parent)
#   3. PATCH git/refs/heads/<ref> with force; when that fails (no such ref),
#      POST git/refs
#   4. GET the ref back, and require the commit sha it names
# Prints one https://github.com/<slug>/blob/<commit>/<name>?raw=true per file,
# rc 0. Any failure: rc 1 and ONE `could not publish: <why>` line, never a
# partial URL list. A re-run moves the ref to the new commit.
#
# Root: ${HARNESS:-${H:-}} only (BH-2613); gh_rest comes from bin/lib/gh-rest.sh
# when the caller has not loaded it.
# shellcheck shell=bash

# The cap is the knob WEB_TASK_MAX_SHOTS (catalog/lanes.d/web-task.json, 1..5);
# 5 is only its fallback.
WT_SHOTS_MAX="${WEB_TASK_MAX_SHOTS:-5}"
[[ "$WT_SHOTS_MAX" =~ ^[1-5]$ ]] || WT_SHOTS_MAX=5

wt_shots_publish() {
  local slug="${1:-}" key="${2:-}" root ref work f n=0 extra=0 name sha tree commit back rc entries="[]" names=()
  root="${HARNESS:-${H:-}}"
  if ! command -v gh_rest >/dev/null 2>&1 && [ -n "$root" ] && [ -r "$root/bin/lib/gh-rest.sh" ]; then
    # shellcheck source=bin/lib/gh-rest.sh
    . "$root/bin/lib/gh-rest.sh"
  fi
  command -v gh_rest >/dev/null 2>&1 || { echo "could not publish: no gh_rest"; return 1; }
  [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "could not publish: bad repo slug"; return 1; }
  [[ "$key" =~ ^[A-Za-z]+-[0-9]+$ ]] || { echo "could not publish: bad ticket key"; return 1; }
  shift 2
  [ "$#" -gt 0 ] || { echo "could not publish: no screenshot files"; return 1; }
  ref="harness-shots/$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')-web-task"
  work=$(mktemp -d "${TMPDIR:-/tmp}/wt-shots.XXXXXX") || { echo "could not publish: no temp dir"; return 1; }
  for f in "$@"; do
    if [ "$n" -ge "$WT_SHOTS_MAX" ]; then extra=$((extra + 1)); continue; fi
    [ -r "$f" ] || { rm -rf "$work"; echo "could not publish: $f is not readable"; return 1; }
    n=$((n + 1)); name=$(basename "$f")
    base64 -w0 "$f" > "$work/b64" && jq -n --rawfile c "$work/b64" '{content: $c, encoding: "base64"}' > "$work/blob.json" \
      || { rm -rf "$work"; echo "could not publish: cannot encode $name"; return 1; }
    rc=0; gh_rest POST "repos/$slug/git/blobs" --input "$work/blob.json" > "$work/out" || rc=$?
    sha=$(jq -r '.sha // empty' "$work/out" 2>/dev/null)
    [ "$rc" = 0 ] && [ -n "$sha" ] || { rm -rf "$work"; echo "could not publish: blob $name (rc $rc)"; return 1; }
    entries=$(jq -c --arg p "$name" --arg s "$sha" '. + [{path: $p, mode: "100644", type: "blob", sha: $s}]' <<<"$entries")
    names+=("$name")
  done
  jq -n --argjson t "$entries" '{tree: $t}' > "$work/tree.json"
  rc=0; gh_rest POST "repos/$slug/git/trees" --input "$work/tree.json" > "$work/out" || rc=$?
  tree=$(jq -r '.sha // empty' "$work/out" 2>/dev/null)
  [ "$rc" = 0 ] && [ -n "$tree" ] || { rm -rf "$work"; echo "could not publish: tree (rc $rc)"; return 1; }
  jq -n --arg t "$tree" --arg m "harness-shots: $key web-task screenshots" '{message: $m, tree: $t, parents: []}' > "$work/commit.json"
  rc=0; gh_rest POST "repos/$slug/git/commits" --input "$work/commit.json" > "$work/out" || rc=$?
  commit=$(jq -r '.sha // empty' "$work/out" 2>/dev/null)
  [ "$rc" = 0 ] && [ -n "$commit" ] || { rm -rf "$work"; echo "could not publish: commit (rc $rc)"; return 1; }
  jq -n --arg s "$commit" '{sha: $s, force: true}' > "$work/patch.json"
  rc=0; gh_rest PATCH "repos/$slug/git/refs/heads/$ref" --input "$work/patch.json" > "$work/out" || rc=$?
  if [ "$rc" != 0 ]; then
    jq -n --arg r "refs/heads/$ref" --arg s "$commit" '{ref: $r, sha: $s}' > "$work/ref.json"
    rc=0; gh_rest POST "repos/$slug/git/refs" --input "$work/ref.json" > "$work/out" || rc=$?
    [ "$rc" = 0 ] || { rm -rf "$work"; echo "could not publish: ref $ref (rc $rc)"; return 1; }
  fi
  rc=0; gh_rest GET "repos/$slug/git/ref/heads/$ref" > "$work/out" || rc=$?
  back=$(jq -r '.object.sha // empty' "$work/out" 2>/dev/null)
  rm -rf "$work"
  [ "$rc" = 0 ] && [ "$back" = "$commit" ] || { echo "could not publish: the ref $ref reads back '${back:-nothing}', not $commit"; return 1; }
  for name in "${names[@]}"; do printf 'https://github.com/%s/blob/%s/%s?raw=true\n' "$slug" "$commit" "$name"; done
  [ "$extra" -gt 0 ] && echo "wt_shots_publish: $extra screenshot(s) over the cap of $WT_SHOTS_MAX were not published" >&2
  return 0
}
