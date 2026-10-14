#!/bin/bash
# bin/lib/lanes-registry.sh — the ONE way anything reads the lane registry.
#
#   lanes_json_path [<root>]   prints an absolute path to a CURRENT
#                              catalog/lanes.json, rendering it from
#                              catalog/lanes.d/ first if it is missing or stale.
#                              rc 0 and a path on stdout, or rc 1 and a reason
#                              on stderr. Nothing else is printed on stdout.
#
# WHY THIS EXISTS (BH-1247). catalog/lanes.json is GENERATED from
# catalog/lanes.d/ and, since this ticket, it is not committed — so a reader
# that opens the path and finds nothing is the normal state of a fresh
# checkout, not an error. Every reader used to spell its own
# `${LANE_REGISTRY:-$SOMEWHERE/catalog/lanes.json}`; four of them did
# (bin/lib/lane-gate.sh, bin/lib/llm-gate.sh, bin/harness-ctl.sh,
# bin/render-cron.sh) and each would have had to learn to render. One loader
# means the render happens at the choke point and every future reader inherits
# it — the same argument BH-1141 made for the LLM call site and BH-1175 made for
# the verification-map index.
#
# WHY IT RENDERS TO catalog/lanes.json AND NOT SOMEWHERE UNDER state/. The
# worker bundles the registry with a STATIC ESM import
# (`worker/jobs/src/lib/core.js`: `import LANES_REGISTRY from
# "../../../../catalog/lanes.json"`), which is resolved by the bundler at build
# time and cannot be pointed anywhere else. Rendering to a second location would
# give the fleet two spellings of one artifact, and the one the worker serves
# would be the one nothing refreshed. So the canonical path stays exactly where
# every reader already looks; it is simply git-ignored now.
#
# STALENESS is keyed on a hash of catalog/lanes.d/ — its file LIST and its
# contents — AND of bin/lanes-build.sh, the script that turns one into the
# other. The renderer belongs in the key because a change to the composition is
# a change to the output with every source byte untouched; without it a box
# keeps serving the previous composition until some unrelated lane file moves
# (BH-1247 review, I2). mtimes were the cheaper option and the wrong one:
# `git checkout`, `cp -a` and rsync all move them in ways that have nothing to
# do with content, so a box that rolled back a branch would keep serving the
# registry it rendered before.
#
# THE STAMP LIVES OUTSIDE THE REPO, under ${TMPDIR:-/tmp}, keyed by a digest of
# the render's absolute path. It used to sit beside the render at
# catalog/.lanes.json.stamp, and that is a file this library writes into a tree
# it does not own: bin/publish-share.sh renders the twelve before sanitizing,
# bin/share/sanitize.py copies the tree by walking it, and bin/share/leakcheck.py
# REFUSES any file with an un-auditable extension — so the public mirror would
# have stopped publishing on every push, silently, which is the exact shape of
# the 2026-09-13 mirror freeze (BH-1247 review, B1). The rule this library now
# keeps is simple and testable: THE ONLY THING IT WRITES INTO THE REPO IS THE
# RENDER. Losing the stamp to a /tmp sweep or a reboot costs one re-render
# (about a second), which is the right price for never writing a second file.
#
# CONCURRENCY. A box runs dozens of lanes a minute and every one of them calls
# this. The render goes to a temp file in the same directory and is moved into
# place, so a concurrent reader sees either the old whole file or the new whole
# file — never a half-written one. Two renders racing produce identical bytes by
# construction (that is what `--check` pins), so whichever lands last is right.
#
# READ-ONLY TREES. If catalog/ cannot be written (a read-only mount, a checkout
# owned by another user) the render goes to ${TMPDIR:-/tmp} under a name that
# carries the source hash, and that path is what is printed. A reader that
# cannot write is still a reader. The one exception is a per-uid stamp directory
# this process does not own (see _lr_stamp): there is then no directory to put
# that shared render beside, so the tier is skipped and an existing render — or
# rc 1 — is the answer instead.
#
# Sourced only, never executed: no `set -e`, no `exit`, nothing runs at source
# time. Callers run under `set -euo pipefail`, so no pipeline in here may fail on
# a happy path.

# _lr_root — the repo root this library was sourced from.
_lr_root() {
  local h
  h=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd) || return 1
  printf '%s' "$h"
}

# _lr_hash <lanes.d dir> <renderer> — a digest of everything the render depends
# on. The listing is hashed as well as the contents: deleting one lane file
# leaves every remaining byte untouched, so a contents-only digest would not
# move and the removed lane would keep its kill switch forever. The RENDERER is
# hashed for the mirror-image reason: a change to bin/lanes-build.sh changes the
# output with every source byte untouched. The knob fragments
# (`<owner>.knobs.d/<ENV>.json`) are hashed last, names and contents, because a
# second file in an existing knob dir changes neither the top listing nor
# `*.json`; with no fragments the key is what it was before they existed.
_lr_hash() {
  local src="$1" renderer="${2:-}"
  { LC_ALL=C ls -1 -- "$src" 2>/dev/null
    LC_ALL=C cat -- "$src"/*.json 2>/dev/null
    [ -n "$renderer" ] && [ -r "$renderer" ] && LC_ALL=C cat -- "$renderer" 2>/dev/null
    LC_ALL=C ls -1 -- "$src"/*.knobs.d 2>/dev/null
    LC_ALL=C cat -- "$src"/*.knobs.d/* 2>/dev/null
  } | cksum 2>/dev/null
}

# _lr_stamp <render path> — where this render's staleness key is kept. Outside
# the repo, named for a digest of the render's absolute path so two checkouts on
# one machine do not share a key. See the header for why it is not in the tree.
#
# IT GOES IN A PER-UID DIRECTORY, not straight into ${TMPDIR:-/tmp}. /tmp is
# world-writable and this runs as root: a bare path there can be pre-planted as
# a symlink, and `printf > that` would follow it (BH-1247 review r2, I2). The
# directory is created 0700 and owned by whoever is running, so another user
# cannot put anything in it.
#
# AND A DIRECTORY THAT IS ALREADY THERE IS NOT AUTOMATICALLY OURS (BH-1304). On
# a shared host somebody can get to that name FIRST, and `mkdir -p` succeeds
# silently on a directory it did not create — so the 0700 above protects only
# the case where we won the race. A pre-existing entry is USED only if it is a
# real directory owned by this euid; a symlink (checked before `-O`, which
# follows one) or another user's directory is REFUSED. Refused means this
# function prints NOTHING and returns 1, and every caller reads that as "no
# stamp": lanes_stamp_write reports rc 1, and lanes_json_path treats the render
# as stale, re-renders, and skips the shared /tmp fallback tier entirely rather
# than aiming it at a directory it was just told not to touch. The cost of a
# refusal is one re-render (about a second), the same price the header already
# accepts for a /tmp sweep.
_lr_stamp() {
  local key dir
  key=$(printf '%s' "$1" | cksum 2>/dev/null | tr -dc '0-9')
  dir="${TMPDIR:-/tmp}/harness-lanes-$(id -u 2>/dev/null || echo 0)"
  # Plain `mkdir`, not `mkdir -p`: -p is exactly the flag that says "fine" to
  # somebody else's directory, which is the case being closed here. The checks
  # on the next line are what decide, so losing the create race — somebody
  # plants the name between the `-e` test and the mkdir — is covered too.
  [ -e "$dir" ] || [ -L "$dir" ] || mkdir -m 700 "$dir" 2>/dev/null || :
  [ ! -L "$dir" ] && [ -d "$dir" ] && [ -O "$dir" ] || return 1
  printf '%s/stamp-%s' "$dir" "${key:-0}"
}

# lanes_stamp_write <root> — record that <root>'s render is current. Exported so
# bin/lanes-build.sh --write/--to can converge with the loader: without it, a
# checkout harness-sync has just composed is re-composed by the next reader.
lanes_stamp_write() {
  local root="${1:-}" want stamp
  [ -n "$root" ] && [ -d "$root/catalog/lanes.d" ] || return 1
  [ -s "$root/catalog/lanes.json" ] || return 1
  want=$(_lr_hash "$root/catalog/lanes.d" "$root/bin/lanes-build.sh")
  [ -n "$want" ] || return 1
  # A refused stamp directory is rc 1, never a write somewhere else: the caller
  # loses one convergence and the next reader re-renders.
  stamp=$(_lr_stamp "$root/catalog/lanes.json") || return 1
  printf '%s\n' "$want" > "$stamp" 2>/dev/null || return 1
}

# lanes_json_path [<root>]
lanes_json_path() {
  local root="${1:-}" src out stamp want have tmp
  # The explicit override wins and is never validated: a suite pointing at a
  # fixture, and bin/agent-call.sh's builder path, both rely on being handed
  # back exactly what they set.
  if [ -n "${LANE_REGISTRY:-}" ]; then printf '%s' "$LANE_REGISTRY"; return 0; fi
  [ -n "$root" ] || root=$(_lr_root) || { echo "lanes-registry: cannot resolve a repo root" >&2; return 1; }
  src="$root/catalog/lanes.d"
  out="$root/catalog/lanes.json"
  # Empty = refused (BH-1304). Held in a variable rather than re-derived so the
  # refusal is decided once, and `|| stamp=""` because callers run under
  # `set -e` and a bare failing assignment would take them down with it.
  stamp=$(_lr_stamp "$out") || stamp=""

  # No sources: a DEPLOYED tree that carries only the render (a share mirror, a
  # tarball) is legitimate, so an existing render is served as-is. Neither one
  # and there is nothing to serve.
  if [ ! -d "$src" ]; then
    [ -s "$out" ] && { printf '%s' "$out"; return 0; }
    echo "lanes-registry: no $src and no $out — nothing to read the registry from" >&2
    return 1
  fi

  want=$(_lr_hash "$src" "$root/bin/lanes-build.sh")
  [ -n "$want" ] || { echo "lanes-registry: could not digest $src" >&2; return 1; }
  if [ -s "$out" ] && [ -n "$stamp" ] && [ -r "$stamp" ]; then
    have=$(cat "$stamp" 2>/dev/null)
    [ "$have" = "$want" ] && { printf '%s' "$out"; return 0; }
  fi

  # Stale or absent: render. `--to` keeps the composition and the placement in
  # one script — this library never learns the registry's shape.
  if tmp=$(mktemp "$root/catalog/.lanes.json.XXXXXX" 2>/dev/null); then
    if "$root/bin/lanes-build.sh" --root "$root" --to "$tmp" >/dev/null 2>&1 && [ -s "$tmp" ]; then
      # `|| :` because a refused stamp is a HAPPY path here — the render landed,
      # there is simply nowhere to record it — and callers run under `set -e`.
      mv -f "$tmp" "$out" 2>/dev/null && [ -n "$stamp" ] && printf '%s\n' "$want" > "$stamp" 2>/dev/null || :
      [ -s "$out" ] && { printf '%s' "$out"; return 0; }
    fi
    rm -f "$tmp" 2>/dev/null
  fi

  # catalog/ is not writable. Render beside the temp dir under the source hash,
  # so a second caller with the same sources reuses the same file.
  #
  # ONLY IF WE HAVE A DIRECTORY (BH-1304). With the stamp dir refused there is no
  # directory to put this beside, and `dirname ""` is `.` — which would drop
  # render-<key>.json into whatever directory the lane happened to be running
  # from, in a library whose one rule is that it writes nothing but the render.
  # So the whole tier is skipped and the last resort below answers instead.
  local key fallback
  if [ -n "$stamp" ]; then
    key=$(printf '%s' "$want" | tr -dc '0-9')
    fallback="$(dirname "$stamp")/render-$key.json"
    [ -s "$fallback" ] && { printf '%s' "$fallback"; return 0; }
    if tmp=$(mktemp "${TMPDIR:-/tmp}/harness-lanes.XXXXXX" 2>/dev/null) \
       && "$root/bin/lanes-build.sh" --root "$root" --to "$tmp" >/dev/null 2>&1 && [ -s "$tmp" ]; then
      mv -f "$tmp" "$fallback" 2>/dev/null && { printf '%s' "$fallback"; return 0; }
    fi
    rm -f "${tmp:-}" 2>/dev/null
  fi
  # Last resort: an existing render, however old, beats no registry at all — a
  # lane that cannot read its kill switch fails OPEN today (bin/lib/lane-gate.sh),
  # and this keeps that behaviour rather than inventing a new failure.
  [ -s "$out" ] && { printf '%s' "$out"; return 0; }
  echo "lanes-registry: could not render $out from $src, and no previous render is readable" >&2
  return 1
}
