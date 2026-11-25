#!/bin/bash
# bin/lib/flow-agent/gates.sh — flow_gates <record-file> <code>: `pass` lets
# flow_act go on; any other word is outcome held. The caps and pauses land in
# BH-9924.3 (#9957).
# owner: BH-9924.3 (#9957)
flow_gates() { echo pass; }
