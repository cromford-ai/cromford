#!/bin/bash
# tests/no-cloud-in-engine.bh-5239-test.sh — BH-5239: the paid Cloud control
# plane moved to example-org/cromford-web, and the engine no longer names its path.
#
# A tracked file may name the Cloud path only when it is:
#   * the dated note docs/notes/2026-10-12-BH-5239-cloud-moved.md;
#   * listed in a fragment under tests/fixtures/no-cloud-in-engine/allow.d/
#     (one repo-relative path per line, '#' and blank lines ignored; a missing
#     dir means no allowances);
#   * under .harness/ (immutable build records of past tickets).
# Each BH-5239 child deletes its files and its own fragment in one PR. When no
# fragment is left, this suite is the strict acceptance test of BH-5239.
#
#   NC-1  every tracked path under the Cloud dir is fragment-listed
#   NC-2  no tests/cloud-*.sh and no tests/schema-fragments-cloud.* tracked
#   NC-3  only the note and fragment-listed paths name the Cloud path; the note
#         is tracked and names example-org/cromford-web
#   NC-3b no stale fragment entry (untracked, or no longer names the path)
#   NC-4  the nc_match table (4 must-match, 5 must-not-match)
#   NC-5  two seeded scratch repos give rc 1 and name the culprits
#   NC-6  the public share mirror has no Cloud dir and no Cloud line (SKIP while
#         a fragment still allows Cloud source)
#
# Seams: NC_ROOT=<repo> checks another checkout (NC-4 and NC-5 then do not run,
# so the inner run never recurses); NC_NO_MIRROR=1 skips NC-6.
# The Cloud path is built by concatenation, so this file never matches itself.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/no-cloud-in-engine.bh-5239-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

P='worker/''cloud'
NC_RE="${P}([^A-Za-z0-9_-]|\$)"
NOTE=docs/notes/2026-10-12-BH-5239-cloud-moved.md
ROOT=${NC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
ALLOW_REL=tests/fixtures/no-cloud-in-engine/allow.d
ALLOW=$ROOT/$ALLOW_REL

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }

# The one matcher. rc 0 when the string names the Cloud path.
nc_match() { grep -qE "$NC_RE" <<<"$1"; }

# Fragment files, sorted (glob order), one per line.
nc_fragments() {
  local f
  [ -d "$ALLOW" ] || return 0
  for f in "$ALLOW"/*.list; do [ -f "$f" ] && echo "$f"; done
}
# $1 = fragment file: its entries, comments and blank lines dropped.
nc_entries() { grep -v '^[[:space:]]*#' "$1" | sed 's/[[:space:]]*$//' | grep -v '^$'; }
# The union of every fragment's entries.
nc_allowed() { local f; nc_fragments | while IFS= read -r f; do nc_entries "$f"; done; }

ALLOWED=$(nc_allowed)
# A here-string, never `printf | grep -q`: under pipefail grep -q exits on the
# first match, printf takes SIGPIPE, and an allowed path reads as not allowed
# (lead review lr-6321-411d51bfa040).
is_allowed() { [ -n "$ALLOWED" ] && grep -Fxq -- "$1" <<<"$ALLOWED"; }

# ── NC-1 ─────────────────────────────────────────────────────────────────────
n=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  is_allowed "$f" || { bad "NC-1: $f is tracked and no fragment lists it"; n=$((n+1)); }
done < <(git -C "$ROOT" ls-files -- "$P")
[ "$n" = 0 ] && ok "NC-1: every tracked path under the Cloud dir is fragment-listed"

# ── NC-2 ─────────────────────────────────────────────────────────────────────
LEFT=$(git -C "$ROOT" ls-files -- 'tests/cloud-*.sh' 'tests/schema-fragments-cloud.*')
if [ -z "$LEFT" ]; then ok "NC-2: no Cloud suite is tracked"
else while IFS= read -r f; do bad "NC-2: Cloud suite still tracked: $f"; done <<< "$LEFT"; fi

# ── NC-3 ─────────────────────────────────────────────────────────────────────
n=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ "$f" = "$NOTE" ] && continue
  is_allowed "$f" || { bad "NC-3: $f names the Cloud path and no fragment lists it"; n=$((n+1)); }
done < <(git -C "$ROOT" grep -lE "$NC_RE" -- . ':!.harness' ":!$ALLOW_REL")
[ "$n" = 0 ] && ok "NC-3: only the dated note and fragment-listed paths name the Cloud path"
if git -C "$ROOT" ls-files --error-unmatch -- "$NOTE" >/dev/null 2>&1 \
   && grep -q 'example-org/cromford-web' "$ROOT/$NOTE"; then
  ok "NC-3: $NOTE is tracked and names example-org/cromford-web"
else
  bad "NC-3: $NOTE is not tracked or does not name example-org/cromford-web"
fi

# ── NC-3b ────────────────────────────────────────────────────────────────────
n=0
while IFS= read -r frag; do
  name=$(basename "$frag")
  while IFS= read -r e; do
    if ! git -C "$ROOT" ls-files --error-unmatch -- "$e" >/dev/null 2>&1; then
      bad "NC-3b: $name: stale entry $e (not tracked)"; n=$((n+1)); continue
    fi
    # An entry under the Cloud dir is its own reference: its path names it.
    case "$e" in "$P"/*) continue ;; esac
    git -C "$ROOT" grep -qE "$NC_RE" -- "$e" \
      || { bad "NC-3b: $name: stale entry $e (no longer names the Cloud path)"; n=$((n+1)); }
  done < <(nc_entries "$frag")
done < <(nc_fragments)
[ "$n" = 0 ] && ok "NC-3b: no stale fragment entry"

if [ -z "${NC_ROOT:-}" ]; then
  # ── NC-4 ───────────────────────────────────────────────────────────────────
  for s in "$P/src/index.js" "see $P." "the old code lived in $P" "      - '$P/**'"; do
    if nc_match "$s"; then ok "NC-4: matches '$s'"; else bad "NC-4: must match '$s'"; fi
  done
  for s in "${P}_fixture/schema.sql" "${P}y/x" "@sentry/cloudflare" "harness-cloud" "www.cloudflare.com"; do
    if nc_match "$s"; then bad "NC-4: must not match '$s'"; else ok "NC-4: does not match '$s'"; fi
  done

  # ── NC-5 ───────────────────────────────────────────────────────────────────
  nc5_repo() { # $1 = dir: an empty git repo with a local identity
    git init -q "$1" && git -C "$1" config user.name nc5 && git -C "$1" config user.email nc5@example.invalid
  }
  # (a) no fragments; a Cloud file and a doc line naming it.
  R="$T/nc5a"
  nc5_repo "$R"
  mkdir -p "$R/$P" "$R/docs"
  echo 'export default {};' > "$R/$P/x.js"
  echo "see $P/x.js" > "$R/docs/a.md"
  git -C "$R" add -A && git -C "$R" commit -qm seed
  OUT=$(NC_ROOT="$R" NC_NO_MIRROR=1 bash "$0" 2>&1); RC=$?
  if [ "$RC" = 1 ] && [[ "$OUT" == *"$P/x.js"* ]] && [[ "$OUT" == *"docs/a.md"* ]]; then
    ok "NC-5a: a seeded Cloud file and doc line give rc 1 and are named"
  else
    bad "NC-5a: want rc 1 naming $P/x.js and docs/a.md, got rc $RC: $OUT"
  fi
  # (b) the note plus one fragment with an untracked entry; nothing else wrong.
  R="$T/nc5b"
  nc5_repo "$R"
  mkdir -p "$R/docs/notes" "$R/$ALLOW_REL"
  printf 'Moved to example-org/cromford-web; it was %s.\n' "$P" > "$R/$NOTE"
  printf '# stale\nbin/gone.sh\n' > "$R/$ALLOW_REL/9-stale.list"
  git -C "$R" add -A && git -C "$R" commit -qm seed
  OUT=$(NC_ROOT="$R" NC_NO_MIRROR=1 bash "$0" 2>&1); RC=$?
  if [ "$RC" = 1 ] && [[ "$OUT" == *"9-stale.list: stale entry bin/gone.sh"* ]]; then
    ok "NC-5b: a stale fragment entry gives rc 1 and is named"
  else
    bad "NC-5b: want rc 1 naming 9-stale.list and bin/gone.sh, got rc $RC: $OUT"
  fi
fi

# ── NC-6 ─────────────────────────────────────────────────────────────────────
if [ "${NC_NO_MIRROR:-}" != 1 ]; then
  HOLD=
  while IFS= read -r frag; do
    if nc_entries "$frag" | grep -q "^$P/"; then HOLD=$(basename "$frag"); break; fi
  done < <(nc_fragments)
  if [ -n "$HOLD" ]; then
    echo "SKIP NC-6: Cloud source still allowed by $HOLD"; PASS=$((PASS+1))
  elif ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP NC-6: python3 is not installed"; PASS=$((PASS+1))
  else
    . "$(dirname "$0")/lib/share-mirror.sh" || exit 1
    share_mirror_get "$ROOT"
    if [ "${SM_SANITIZE_RC:-x}" != 0 ]; then
      bad "NC-6: the mirror sanitize exited ${SM_SANITIZE_RC:-unset}"
    else
      if [ ! -e "$SM_MIRROR/$P" ]; then ok "NC-6: the mirror has no Cloud dir"
      else bad "NC-6: the mirror has $P"; fi
      HITS=$(grep -rlE "$NC_RE" "$SM_MIRROR" 2>/dev/null | grep -vF "/$(basename "$NOTE")")
      if [ -z "$HITS" ]; then ok "NC-6: no mirror file names the Cloud path"
      else bad "NC-6: mirror files name the Cloud path: $HITS"; fi
    fi
  fi
fi

echo "no-cloud-in-engine.bh-5239: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
