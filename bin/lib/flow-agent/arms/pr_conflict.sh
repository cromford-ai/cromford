#!/bin/bash
# bin/lib/flow-agent/arms/pr_conflict.sh — flow_arm_pr_conflict <record-file>:
# rc 0 done, 1 failed, 3 refused; stdout is the detail. Placeholder: refused.
# owner: BH-9924.8 (#9958)
flow_arm_pr_conflict() { echo not-built; return 3; }
