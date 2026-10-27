#!/bin/bash
# bin/lib/fly-pool-build-guard.sh — merge guard seam for bin/fly-pool-build.sh
# --write (BH-7454). Sourced, never executed. --write calls fpb_merge_guard
# after the fragments validate and before it replaces bin/fly-pool.sh; a nonzero
# rc stops the write with that rc.
# owner: BH-7454.2 (issue #7543, merge guard)
# Placeholder: no guard yet, so every write may go ahead.

fpb_merge_guard() { return 0; }
