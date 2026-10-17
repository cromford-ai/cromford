#!/bin/bash
# bin/ci-node-modules.sh — in the cromford CI image, give a checkout the
# node_modules the image baked from the same lockfile (BH-7255).
#
#   ci-node-modules.sh <dir> <name>
#
# <dir> is the package directory in the checkout (worker/jobs, console-ui);
# <name> is the baked tree under /opt/ci/node (worker-jobs, console-ui).
# ci-images/cromford/Dockerfile runs `npm ci` there and writes
# .lock-sha256, the sha256 of the lockfile it installed from.
#
# IMAGE MODE ONLY. The workflow calls this in the step that runs when
# needs.ci-image.outputs.ref is set. The host path keeps its own `npm ci` step,
# unchanged. So a missing baked tree is an image that is broken, never a cue to
# install: this exits 1 by name instead of running npm ci behind the image.
#
#   rc 0  <dir>/node_modules is a symlink to the baked tree, whose lockfile
#         hash equals <dir>/package-lock.json's
#   rc 1  no baked tree, a hash mismatch (the tag missed an input), or a real
#         <dir>/node_modules is already there (it is never deleted)
#   rc 2  misuse
#
# Test seam: CI_NODE_BAKED_ROOT (default /opt/ci/node).
set -uo pipefail

DIR="${1:-}"; NAME="${2:-}"
if [ $# -ne 2 ] || [ -z "$DIR" ] || ! [[ "$NAME" =~ ^[a-z0-9-]+$ ]]; then
  echo "usage: ci-node-modules.sh <package dir> <baked tree name>" >&2; exit 2
fi
BAKED="${CI_NODE_BAKED_ROOT:-/opt/ci/node}/$NAME"
LOCK="$DIR/package-lock.json"
err() { echo "::error::ci-node-modules: $NAME: $*"; exit 1; }

[ -r "$LOCK" ] || err "no $LOCK in the checkout"
[ -d "$BAKED/node_modules" ] || err "the image has no baked tree at $BAKED/node_modules"
want=$(cat "$BAKED/.lock-sha256" 2>/dev/null) || err "no $BAKED/.lock-sha256"
got=$(sha256sum "$LOCK" | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$got" ] \
  || err "the baked tree is from lockfile ${want:-<empty>}, the checkout's $LOCK is $got (the image tag missed an input)"
if [ -e "$DIR/node_modules" ] && [ ! -L "$DIR/node_modules" ]; then
  err "$DIR/node_modules already exists and is not a link; it is left as it is"
fi
ln -sfn "$BAKED/node_modules" "$DIR/node_modules" || err "cannot link $DIR/node_modules"
echo "ci-node-modules: $DIR/node_modules -> $BAKED/node_modules (lockfile $got)"
