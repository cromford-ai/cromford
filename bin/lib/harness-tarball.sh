#!/bin/bash
# bin/lib/harness-tarball.sh — harness_tarball <out.tgz> <checkout> <paths...>
# Tars the harness runtime for a Fly machine and stamps HARNESS_COMMIT (the
# checkout's full HEAD sha) at the tarball root (BH-1632). Machines run from
# /data/harness with no .git, so the stamp is the only way they can say which
# harness they run. rc 0 = stamped; rc 2 = rev-parse failed, tree shipped with
# NO stamp (never a guessed one); rc 1 = tar failed.
harness_tarball() {
  local out="$1" checkout="$2"; shift 2
  local sha stampdir rc=0
  # BH-7505: POOL_HARNESS_SRC, when set, is the checkout to tar. A lane-run
  # machine that runs the pool tick has no /root/harness-checkout; the hub sets
  # nothing, so its call names the same checkout as before.
  [ -z "${POOL_HARNESS_SRC:-}" ] || checkout="$POOL_HARNESS_SRC"
  stampdir=$(mktemp -d /tmp/hstamp-XXXX)
  if sha=$(git -C "$checkout" rev-parse HEAD 2>/dev/null) && [ ${#sha} = 40 ]; then
    printf '%s\n' "$sha" > "$stampdir/HARNESS_COMMIT"
    tar czf "$out" -C "$checkout" "$@" -C "$stampdir" HARNESS_COMMIT 2>/dev/null || rc=1
  else
    tar czf "$out" -C "$checkout" "$@" 2>/dev/null || rc=1
    [ "$rc" = 0 ] && rc=2
  fi
  rm -rf "$stampdir"
  return "$rc"
}
