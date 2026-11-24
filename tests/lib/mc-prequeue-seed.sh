#!/bin/bash
# tests/lib/mc-prequeue-seed.sh — BH-9756: the reduced seed tree for Part 2 of
# tests/mc-prequeue-fast-lints.bh-8473-test.sh. Sourced; defines one function.
#
#   pq_seed_tree <src_dir> <dest_dir>
#
# Copies the files of <src_dir> that git lists (tracked and untracked, not
# ignored) into <dest_dir>, minus the paths in PQ_SEED_EXCLUDE, plus the
# PQ_SEED_KEEP paths under tests/. It then makes an empty <dest_dir>/docs
# (the BH-8473 fixture heads write a file there). Returns non-zero when a step
# fails.
#
# Why: Part 2 used to seed the whole checkout (177.6 MB, 16992 files on
# 2026-11-24, growing with every merge). The real conductor's snapshot build
# (rp_snapshot_build, bin/lib/mc-prequeue.d/fast-lints.sh) then ran out of its
# call budget, and the suite went red on main.
#
# Part 2 runs only the `lanes-registry` row of catalog/prequeue-fast-lints.tsv
# (LANES_REGISTRY_SECTIONS=static bash tests/lanes-registry-test.sh). That
# suite reads bin/, fleet.conf, catalog/, cron/ and tests/lib/. If it starts to
# read a path this seed drops, the BH-8473 suite goes red on A2 (a clean head
# must be enqueued) and tests/mc-prequeue-seed.bh-9756-test.sh goes red on S2.

# Each entry is a top-level path Part 2 does not read:
#   .harness/specs  plan archives; read by no fast lint and not by the conductor
#   docs            no reader in tests/lanes-registry-test.sh or bin/lanes-build.sh;
#                   pq_seed_tree makes an empty docs/ for the fixture heads
#   console-ui      the console app; no reader in the static lanes-registry sections
#   tests           the suite corpus; only PQ_SEED_KEEP below is read
PQ_SEED_EXCLUDE=".harness/specs docs console-ui tests"
# Paths under an excluded path that Part 2 does read:
#   tests/lib                     sourced by tests/lanes-registry-test.sh (scratch.sh, rendered.sh)
#   tests/lanes-registry-test.sh  the fast lint itself
PQ_SEED_KEEP="tests/lib tests/lanes-registry-test.sh"

pq_seed_tree() {
  local src="$1" dest="$2" p
  local -a ex=()
  [ -d "$src" ] && [ -n "$dest" ] || return 2
  mkdir -p "$dest" || return 1
  for p in $PQ_SEED_EXCLUDE; do ex+=(":(exclude)$p"); done
  # shellcheck disable=SC2086 # PQ_SEED_KEEP is a word list of paths
  { git -C "$src" ls-files -co --exclude-standard -z -- . "${ex[@]}" \
      && git -C "$src" ls-files -co --exclude-standard -z -- $PQ_SEED_KEEP; } \
    | ( cd "$src" && tar --null -T - -cf - ) | tar -C "$dest" -xf - || return 1
  mkdir -p "$dest/docs"
}
