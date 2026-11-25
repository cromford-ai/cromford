#!/bin/bash
# bin/lib/flow-agent/arms/waits_behind_green_pr.sh — flow_arm_waits_behind_green_pr <record-file>:
# rc 0 done, 1 failed, 3 refused; stdout is the detail. Placeholder: refused.
# owner: BH-9924.6 (#9957)
flow_arm_waits_behind_green_pr() { echo not-built; return 3; }
