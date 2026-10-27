#!/bin/bash
# bin/lib/fly-pool-build-absorb.sh — absorb seam for bin/fly-pool-build.sh
# --absorb (BH-7454). Sourced, never executed. --absorb returns fpb_absorb's rc.
# owner: BH-7454.3 (issue #7544, absorb)
# Placeholder: absorb is not built, so it refuses with rc 2.

fpb_absorb() {
  echo "fly-pool-build: --absorb is not built yet (BH-7454.3)" >&2
  return 2
}
