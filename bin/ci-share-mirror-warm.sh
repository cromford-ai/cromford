#!/bin/bash
# bin/ci-share-mirror-warm.sh <list-file> — build the public mirror once for a
# CI shard, untraced, before the traced run reads it.
#
# Every suite that sources tests/lib/share-mirror.sh calls share_mirror_get,
# which builds the mirror when its cache has no entry for the tree. Under the
# CI tracer that build is about 2x its untraced cost, and a shard that held
# several share-mirror suites passed its 45-minute job cap. This step fills
# the SAME cache (${SHARE_MIRROR_CACHE:-$TMPDIR/bh-share-mirror}) through the
# SAME function, so the traced suites then log `share-mirror: reused <key12>`.
#
# <list-file> holds repo-relative suite paths, one per line (the output of
# `bin/test-trace-safety.sh --list --gate --shard i/n --only-file <impact>`).
# The step builds only when a listed *.sh has a line that sources
# lib/share-mirror.sh; a comment that names the lib is not a consumer.
#
# It exports no bin/lib/deployment.sh knob (tests/lib/share-mirror.sh: the
# first build of a key decides the cached tree for every later suite).
#
# FAIL-OPEN: rc 0 always. A failure prints one `::warning::share-mirror-warm:`
# line, and each suite then builds for itself, as before this step existed.
#   share-mirror-warm: no share-mirror suite in this shard
#   share-mirror-warm: built|reused <key12> (<n> consumer suite(s) in the list)
set -uo pipefail
warn() { echo "::warning::share-mirror-warm: $*"; exit 0; }

LIST="${1:-}"
[ -n "$LIST" ] || warn "no list file given; each share-mirror suite builds for itself"
[ -r "$LIST" ] && [ -f "$LIST" ] || warn "cannot read the list file '$LIST'; each share-mirror suite builds for itself"
ROOT=$(pwd)

N=0
while IFS= read -r REL || [ -n "$REL" ]; do
  case "$REL" in *.sh) ;; *) continue ;; esac
  [ -f "$ROOT/$REL" ] || continue
  grep -qE '^[[:space:]]*(\.|source)[[:space:]].*lib/share-mirror\.sh' "$ROOT/$REL" 2>/dev/null && N=$((N + 1))
done < "$LIST"
if [ "$N" -eq 0 ]; then
  echo "share-mirror-warm: no share-mirror suite in this shard"
  exit 0
fi
[ -r "$ROOT/tests/lib/scratch.sh" ] && [ -r "$ROOT/tests/lib/share-mirror.sh" ] \
  || warn "tests/lib/scratch.sh or tests/lib/share-mirror.sh is missing in $ROOT"

# The build runs in a subshell: scratch.sh sets an EXIT trap and $T there, and
# both stay inside it. Its result comes back as one line on fd 3.
RES=$( (
  export HARNESS_TEST_SANDBOX=1
  # shellcheck source=../tests/lib/scratch.sh
  . "$ROOT/tests/lib/scratch.sh" >&2 || exit 1
  # shellcheck source=../tests/lib/share-mirror.sh
  . "$ROOT/tests/lib/share-mirror.sh" >&2 || exit 1
  share_mirror_get "$ROOT" >&2 || exit 1
  echo "${SM_HOW:-} ${SM_SANITIZE_RC:-} $(basename "${SM_DIR:-}")" >&3
) 3>&1 ); RC=$?
HOW=${RES%% *}; REST=${RES#* }; SRC_RC=${REST%% *}; KEY=${REST#* }
[ "$RC" -eq 0 ] || warn "share_mirror_get exited $RC; each share-mirror suite builds for itself"
case "$HOW" in
  built|reused)
    [ "$SRC_RC" = 0 ] || warn "the mirror build has sanitize rc=$SRC_RC; each share-mirror suite builds for itself"
    echo "share-mirror-warm: $HOW ${KEY:0:12} ($N consumer suite(s) in the list)" ;;
  *) warn "the mirror build was '${HOW:-none}' (sanitize rc=${SRC_RC:-none}), not cached; each share-mirror suite builds for itself" ;;
esac
exit 0
