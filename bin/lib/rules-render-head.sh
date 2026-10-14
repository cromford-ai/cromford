#!/bin/bash
# bin/lib/rules-render-head.sh — BH-5325: does `bin/render-rules.sh --check`
# pass on a PR head? The proof the risk tier's rules-text lane needs (rule 2b,
# bin/lib/risk-tier.sh). Sourced (by bin/lead-review-enqueue.sh), never executed.
#
# rrh_check <git-dir> <head-sha> <renderer>
#   Fetches <head> into the checkout <git-dir> (`git fetch --no-write-fetch-head
#   origin <head>`: no ref and no FETCH_HEAD, so it never races another lane's
#   fetch of the same shared checkout), extracts the head's rules/ tree with
#   `git archive` into a scratch dir, and runs `<renderer> --root <scratch>
#   --check` on it. The renderer is the CALLER's (the hub's deployed copy),
#   never the head's own script. Prints ONE line, `<answer>\t<detail>`:
#     ok      the render check passed on the head
#     drift   it found drift (detail: the first `<`/`>` diff line)
#     unread  anything else: no checkout, a head that is not a full sha, no
#             executable renderer, a fetch, archive or render that failed or
#             timed out, or a symlink anywhere in the head's rules/ tree (the
#             renderer follows it, and a drift line would print the target's
#             content) (detail: which). Unread is never ok.
#   Always rc 0. The scratch dir is removed on every path. Every git and render
#   call runs under `timeout` (fetch 120 s, archive 60 s, render 60 s).
# Needs git, tar, timeout. No harness root: the caller names every path.

rrh_check() {
  local dir="${1:-}" head="${2:-}" renderer="${3:-}" scratch out rc first
  [ -n "$dir" ] && { [ -d "$dir/.git" ] || [ -f "$dir/HEAD" ]; } \
    || { printf 'unread\tno checkout at %s\n' "${dir:-<none>}"; return 0; }
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { printf 'unread\thead %s is not a full sha\n' "${head:-<none>}"; return 0; }
  [ -n "$renderer" ] && [ -x "$renderer" ] || { printf 'unread\tno renderer at %s\n' "${renderer:-<none>}"; return 0; }
  rc=0; timeout 120 git -C "$dir" fetch -q --no-write-fetch-head origin "$head" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || { printf 'unread\tfetch of %s failed (rc %s)\n' "${head:0:12}" "$rc"; return 0; }
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/rules-render-head.XXXXXX") || { printf 'unread\tmktemp failed\n'; return 0; }
  # Both sides of the pipe must succeed, whatever the caller's pipefail is.
  timeout 60 git -C "$dir" archive "$head" rules 2>/dev/null | tar -x -C "$scratch" >/dev/null 2>&1
  rc="${PIPESTATUS[0]}${PIPESTATUS[1]}"
  if [ "$rc" != 00 ]; then
    rm -rf "$scratch"; printf 'unread\tno rules/ tree on %s (rc %s)\n' "${head:0:12}" "$rc"; return 0
  fi
  if [ -n "$(find "$scratch" -type l -print -quit 2>/dev/null)" ]; then
    rm -rf "$scratch"; printf 'unread\ta symlink in the rules/ tree on %s\n' "${head:0:12}"; return 0
  fi
  rc=0; out=$(timeout 60 "$renderer" --root "$scratch" --check 2>&1) || rc=$?
  rm -rf "$scratch"
  case "$rc" in
    0) printf 'ok\trender check passed on %s\n' "${head:0:12}" ;;
    1) first=$(grep -m1 -E '^[<>] ' <<<"$out" || true)
       [ -n "$first" ] || first=$(head -1 <<<"$out")
       printf 'drift\t%s\n' "$(printf '%s' "$first" | tr '\t' ' ' | head -c 200)" ;;
    *) printf 'unread\trender check rc %s\n' "$rc" ;;
  esac
  return 0
}
