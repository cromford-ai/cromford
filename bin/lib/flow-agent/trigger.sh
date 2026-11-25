#!/bin/bash
# bin/lib/flow-agent/trigger.sh — flow_trigger <project>: the word that starts
# a pass from `bin/flow-agent.sh tick`. `none` runs no pass. The event trigger
# lands in BH-9924.2 (#9957); until then tick never runs a pass.
# owner: BH-9924.2 (#9957)
flow_trigger() { echo none; }
