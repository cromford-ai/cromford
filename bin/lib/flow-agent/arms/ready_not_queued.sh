#!/bin/bash
# bin/lib/flow-agent/arms/ready_not_queued.sh — flow_arm_ready_not_queued <record-file>:
# rc 0 done, 1 failed, 3 refused; stdout is the detail. Placeholder: refused.
# owner: BH-9924.4 (#9957)
flow_arm_ready_not_queued() { echo not-built; return 3; }
